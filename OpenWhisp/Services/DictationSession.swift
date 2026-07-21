import Foundation

/// Who initiated a dictation session.
///
/// A **user** session behaves exactly as OpenWhisp always has: it pastes its
/// result into the frontmost app. An **agent** session (started via the Agent
/// Bridge) instead returns the transcript to the calling client and pastes
/// nothing — the microphone and overlay are the same, only the disposition of
/// the result differs.
///
/// Foundation-only so it lives in `OpenWhispCore` and can be unit-tested; the app
/// carries it through the existing session funnel, and the future
/// `DictationCoordinator` (M8 step 9) will own it.
public enum SessionInitiator: Equatable {
    case user
    /// `biasTerms`: session-scoped workspace-context bias terms (MAK-75), derived
    /// from the client's cwd/branch/file names via `AgentContextVocabulary`.
    /// Carried ON the initiator so their lifecycle is exactly the agent session's
    /// — they exist only while the initiator is `.agent`, vanish when it resets to
    /// `.user`, and are never persisted anywhere.
    case agent(client: String, prompt: String?, biasTerms: [String] = [])

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// The claimed client name for an agent session (display-only; never trusted
    /// for authorization — the socket peer's code signature is what authorizes).
    public var clientName: String? {
        if case let .agent(client, _, _) = self { return client }
        return nil
    }

    /// The agent's prompt to show in the overlay, if any.
    public var prompt: String? {
        if case let .agent(_, prompt, _) = self { return prompt }
        return nil
    }

    /// Workspace-context bias terms for an agent session (MAK-75); empty for a
    /// user session or an agent session that passed no context.
    public var agentBiasTerms: [String] {
        if case let .agent(_, _, terms) = self { return terms }
        return []
    }
}

/// Decisions about the dictation-session lifecycle that must stay consistent
/// across the (ordering-sensitive) start/cancel/finish sites. Pure so the
/// invariant is unit-tested rather than re-derived at each call site.
public enum DictationSessionLifecycle {
    /// Whether `finishSessionUI` should reset the hotkey activation machine when a
    /// session ends.
    ///
    /// It must NOT reset while a preempt-replacement start is queued
    /// (`pendingPreemptStart`): there the activation machine's current state
    /// (mid-press or locked-open) describes the user's NEW session, and wiping it
    /// would swallow the upcoming release — in hold mode the preempt-started mic
    /// would then never stop on release.
    ///
    /// This is why the agent-preempt path in `startDictation` must set
    /// `pendingPreemptStart` BEFORE calling `cancelDictation` (which runs
    /// `finishSessionUI`): the flag has to be visible here, or the reset fires and
    /// the release is lost.
    public static func shouldResetActivation(pendingPreemptStart: Bool) -> Bool {
        !pendingPreemptStart
    }
}

/// The terminal outcome of a dictation session, delivered exactly once to an
/// agent-initiated waiter (see `AppState.onSessionEnd`).
///
/// `cancelled` is the default when a session ends without recording a more
/// specific outcome (an abort before capture, or an error terminal that didn't
/// set one) — so a waiter is never left hanging, and per the cancel invariant a
/// cancelled session yields no transcript text.
/// Maps a finished agent session's `SessionOutcome` (+ the timed-out / stopped
/// flags recorded during the session) onto the wire result delivered to the
/// blocked dictate caller. Pure — extracted from AppState's `onSessionEnd`
/// closure so the endedBy / error precedence is unit-testable:
///  - completed → success; endedBy = timeout > stop > user.
///  - empty     → timeout error if timed out, else an empty success.
///  - secureField / cancelled / error → the corresponding domain errors
///    (a cancel NEVER yields a transcript, per the cancel invariant).
public enum AgentDictateOutcome {
    public static func resolve(
        _ outcome: SessionOutcome, duration: Double, timedOut: Bool, stopped: Bool
    ) -> Result<BridgeWire.DictateResult, BridgeWire.ErrorObject> {
        let endedBy: BridgeWire.DictateEnd = timedOut ? .timeout : (stopped ? .stop : .user)
        switch outcome {
        case .completed(let text):
            return .success(.init(text: text, durationSeconds: duration, timedOut: timedOut, endedBy: endedBy))
        case .empty:
            return timedOut
                ? .failure(.domain(.timeout, message: "no speech within the time limit"))
                : .success(.init(text: "", durationSeconds: duration, timedOut: false, endedBy: stopped ? .stop : .user))
        case .secureField:
            return .failure(.domain(.secureField, message: "a password field was focused; dictation refused"))
        case .cancelled:
            return .failure(.domain(.cancelled, message: "the user declined to answer — do not retry"))
        case .error(let message):
            return .failure(.domain(.audioUnavailable, message: message))
        }
    }
}

/// The overlay presentation of an agent's dictate request: the attribution line
/// ("X asks: …"), the quiet client eyebrow, and the hero question. Sanitized
/// (control/bidi stripped, capped) and always framed as the CLIENT asking —
/// agent-controlled text must never read as OpenWhisp's own voice. `question` is
/// nil (not empty) when the agent gave no prompt so the overlay falls back
/// cleanly. Extracted from AppState so the framing rules are unit-testable.
public struct AgentPromptPresentation: Equatable {
    public let banner: String
    public let clientLabel: String
    public let question: String?

    public init(clientName: String, prompt: String?) {
        let displayClient = BridgeWire.sanitizedForDisplay(clientName, maxLength: 60)
        clientLabel = displayClient.isEmpty ? "An agent" : displayClient
        let displayQuestion = prompt.map { BridgeWire.sanitizedForDisplay($0, maxLength: 200) } ?? ""
        question = displayQuestion.isEmpty ? nil : displayQuestion
        banner = displayQuestion.isEmpty
            ? "\(clientLabel) asked you to dictate"
            : "\(clientLabel) asks: \(displayQuestion)"
    }
}

public enum SessionOutcome: Equatable {
    /// Produced final text (which may itself be any non-nil string).
    case completed(text: String)
    /// The session finalized with nothing transcribed.
    case empty
    /// Refused because a secure text field was focused.
    case secureField
    /// The user pressed Esc, or the client cancelled. No transcript is returned.
    case cancelled
    /// An audio/engine error aborted the session.
    case error(message: String)
}

/// The Foundation-clean inventory of a dictation session's mutable state
/// (MAK-8 step 9a — the first strangler slice of the `DictationCoordinator`
/// extraction). Every field here previously lived as a `private var` on the
/// AppKit-only `AppState`; gathering them into one Foundation-only value type
/// is the seam that later steps (9b: move the lifecycle funnel; 9c: flip the
/// hotkey/bridge drivers) build on.
///
/// **9a keeps behavior byte-identical.** No lifecycle logic moves in this step:
/// `AppState` now stores a single `DictationSessionState` and exposes each field
/// through a pass-through computed property, so every hand-written guard reads
/// and writes exactly the same values in the same order it always did. The only
/// change is *where the bytes live*.
///
/// **What is NOT here.** `AppState.targetApplication` stays on `AppState`: its
/// type is `NSRunningApplication?` (AppKit), which this Foundation-only core
/// package cannot name. `onSessionEnd` (a closure delivering the terminal
/// outcome to an agent waiter) likewise stays on `AppState` — it is an IO/UI
/// side-effect sink, not session state. `@Published` overlay-cue mirrors
/// (`refineArmed`, `refineContentSnapshot`, `refineActiveInstruction`,
/// `clipboardFallbackActive`) also stay on `AppState`, since they must drive
/// SwiftUI republishing.
///
/// Defaults reproduce AppState's original initializers exactly, so a freshly
/// constructed value is the idle session and `reset()` returns to it.
public struct DictationSessionState: Equatable {
    // MARK: Session identity & liveness

    /// The generation fence. Every session start mints a fresh id; async
    /// callbacks (transcription results, recorder state changes, LLM completions)
    /// compare their captured id against this and drop themselves if a newer
    /// session has begun. This is the "never lose text / never leak a stale
    /// session's text" guard.
    public var activeSessionID = UUID()
    /// The session that last started the `AudioRecorder`. The recorder's
    /// `onStateChanged` callback is wired once (not per-session) and delivers
    /// through a main-actor Task hop, so a state change from a cancelled session
    /// can land after the next session already began; comparing this against
    /// `activeSessionID` drops those stale transitions.
    public var recorderSessionID: UUID?
    /// True from `beginSession()` until the session terminates. Tracks dictation
    /// intent independently of `isRecording`, which only flips true inside async
    /// grant callbacks.
    public var sessionActive = false
    /// Set when a stop arrives before the grant callback has started recording.
    public var pendingStop = false
    /// Set while a preempt-deferred `startDictation` is queued (an agent session
    /// was cancelled this turn; the user's session starts next turn). A stop or
    /// cancel arriving in that one-turn gap consumes the flag so the deferred
    /// start no-ops instead of arming a session whose stop already passed.
    public var pendingPreemptStart = false

    // MARK: Captured text & streaming bookkeeping

    /// The session's accumulating transcript (drives the overlay; the source of
    /// the final text when a session completes).
    public var currentSessionText = ""
    public var isStreamingSession = false
    public var acceptingLiveChunks = false

    // MARK: Enhancement / initiator / outcome

    public var openAIEnhancementEnabledForSession = false
    /// Session snapshot of "return the transcript, don't paste it", frozen in
    /// `beginSession()` from the initiator and cleared in `finishSessionUI()`.
    public var suppressOutput = false
    /// Who started the current session; set before `beginSession()` and reset to
    /// `.user` in `finishSessionUI()`.
    public var sessionInitiator: SessionInitiator = .user
    /// The outcome recorded at the session's terminal point, read once by
    /// `onSessionEnd` in `finishSessionUI()`. Defaults to `.cancelled` if never
    /// set (abort, or an error terminal that didn't record one).
    public var sessionOutcome: SessionOutcome?

    // MARK: Per-session snapshots (frozen at beginSession so a mid-session
    // settings change can't change the paste/edit behavior partway through)

    public var isLiveChunkSession = false
    public var isPreviewSession = false
    public var isAppleSpeechSession = false
    public var appleLiveInsertedText = ""
    public var appleDidCompleteFinal = false
    /// Whether spoken edit commands are honored for THIS session.
    public var voiceEditingActiveForSession = false
    /// The session's edit buffer; only read when `voiceEditingActiveForSession`.
    public var voiceEditBuffer = VoiceEditBuffer()

    // MARK: Per-app profile override backups (restored when the session ends)

    /// Global setting values saved before a per-app profile temporarily overrode
    /// them for the current session.
    public var profileOverrideBackup: ProfileOverrideBackup?
    /// The refine instruction contributed by the Mode active for the current
    /// session (composed tone + free-form instruction), or nil.
    public var modeRefineInstructionOverride: String?
    /// Per-app refine-preset prompt (MAK-77); same lifecycle as the Mode override.
    public var presetRefineInstructionOverride: String?
    /// A per-app profile's text-insert method for the CURRENT session (MAK-42),
    /// or nil when no profile overrides it.
    public var sessionInsertionModeOverride: InsertionMode?
    /// While a per-app profile override is in effect, don't persist the overridden
    /// settings to UserDefaults.
    public var suppressSettingsPersistence = false

    public init() {}

    /// Reset to the idle session (a fresh `activeSessionID`, everything else
    /// cleared). Mirrors AppState's teardown of the session inventory; used by the
    /// `cancel` / abort paths that re-arm the fence.
    public mutating func reset() {
        self = DictationSessionState()
    }
}

/// The four global setting values a per-app profile can temporarily override,
/// saved so they can be restored when the session ends. Named struct (vs. the
/// former anonymous tuple on AppState) so it can be `Equatable` and cross the
/// core boundary.
public struct ProfileOverrideBackup: Equatable {
    public var language: String
    public var translateToEnglish: Bool
    public var outputMode: String
    public var aiCleanup: Bool

    public init(language: String, translateToEnglish: Bool, outputMode: String, aiCleanup: Bool) {
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.outputMode = outputMode
        self.aiCleanup = aiCleanup
    }
}

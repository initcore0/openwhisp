import Foundation

/// The pure interaction layer that turns raw trigger *edges* (the debounced
/// down/up that `HotkeyGesture` already resolves) into high-level dictation
/// *intents* — start, stop, cancel — for BOTH activation styles:
///
/// - **Hold** (press-to-talk, the historical behavior): the session lives for
///   exactly as long as the trigger is held. Down → `.start`, up → `.stop`.
/// - **Toggle** (hands-free lock, MAK-16): a *tap* starts the session and leaves
///   it locked open; a second tap (or Esc) stops it. Holding the trigger past the
///   tap window falls back to press-to-talk within the same session, so a user who
///   simply holds the key never accidentally leaves the mic locked open.
///
/// A **double-tap** while in hold mode is also a way into the lock: tap-tap
/// (both taps quick, and close together) starts a locked session even though the
/// mode setting is "hold". This is the "gesture" alternative called for by the
/// ticket, so lock mode is reachable without visiting Settings.
///
/// The whole thing is a pure, clock-driven state machine so every path — tap vs.
/// hold vs. double-tap timing, toggle start/stop, and the safety auto-stop
/// arming decision — is unit-testable with `swift test`. It owns no timers and
/// touches no audio or AppKit APIs: `HotkeyMonitor` feeds it edges + a monotonic
/// clock and acts on the returned intent; `AppState` never re-derives any of this.
///
/// The interaction state deliberately lives HERE, not in `AppState` (which is
/// AppKit-only and untestable) — the same rule the refine/silence machines follow.
public struct ActivationInteraction {

    /// How a press activates dictation.
    public enum Mode: Equatable {
        /// Press-to-talk: session lives while the trigger is held. A quick
        /// double-tap still escalates to a locked session (the gesture path).
        case hold
        /// Hands-free: a tap locks the session open; tap/Esc stops it. A long
        /// press on the initial tap still degrades to press-to-talk.
        case toggle
    }

    /// What the caller should do in response to an edge. Exactly one intent per
    /// edge (or `.none`); the caller owns the actual session lifecycle.
    public enum Intent: Equatable {
        /// Begin a dictation session. `locked` is true when the session is
        /// hands-free (stays open until an explicit stop/cancel), false for an
        /// ordinary press-to-talk hold.
        case start(locked: Bool)
        /// End the active session normally (deliver the transcript).
        case stop
        /// Cancel the active session (discard it) — from Esc.
        case cancel
        /// No externally-visible change.
        case none
    }

    /// Tunable timing. Defaults match `RefineTapRecognizer.maxTapDuration` for a
    /// consistent "what counts as a tap" feel across the app.
    public struct Config: Equatable {
        /// Longest press that still counts as a *tap* (vs. a deliberate hold).
        public var maxTapDuration: TimeInterval
        /// Longest gap between two taps for them to read as a double-tap.
        public var doubleTapGap: TimeInterval

        public init(maxTapDuration: TimeInterval = 0.6, doubleTapGap: TimeInterval = 0.4) {
            self.maxTapDuration = maxTapDuration
            self.doubleTapGap = doubleTapGap
        }

        public static let `default` = Config()
    }

    /// Internal lifecycle.
    private enum Phase: Equatable {
        /// No session. Optionally remembers the timestamp of the last tap-release
        /// so the *next* press can be recognized as the second half of a
        /// double-tap (only meaningful in hold mode).
        case idle(lastTapReleasedAt: TimeInterval?)
        /// Trigger down, session started, waiting to see if it's a tap or a hold.
        /// `startedLocked` records whether this session started as a lock (toggle
        /// mode, or the second tap of a double-tap) — a lock is never downgraded
        /// by the release *unless* the press turned out to be a long hold.
        case pressed(downAt: TimeInterval, startedLocked: Bool)
        /// A deliberate hold (press-to-talk). Ends on the trigger release.
        case held
        /// Hands-free: the session is locked open. The trigger is up; the session
        /// persists until a stop tap or Esc.
        case lockedOpen
        /// Transitional: the stop tap's DOWN edge already fired `.stop`; its
        /// matching release must be swallowed so it doesn't start a new session.
        case stoppingLock
    }

    private let mode: Mode
    private let config: Config
    private var phase: Phase = .idle(lastTapReleasedAt: nil)

    public init(mode: Mode, config: Config = .default) {
        self.mode = mode
        self.config = config
    }

    /// Whether a session is currently active (held or locked open). The caller
    /// uses this to keep its own view of "is dictation live" in sync.
    public var isActive: Bool {
        switch phase {
        case .idle, .stoppingLock: return false
        case .pressed, .held, .lockedOpen: return true
        }
    }

    /// Whether the active session is a hands-free lock (drives the overlay's
    /// "locked — tap or Esc to stop" affordance and the silence safety auto-stop).
    /// True from the moment a lock is decided — including during the initial
    /// `pressed` phase of a toggle/double-tap start, so the affordance can show
    /// immediately rather than only after the first release.
    public var isLockedOpen: Bool {
        switch phase {
        case .lockedOpen: return true
        case .pressed(_, let startedLocked): return startedLocked
        case .idle, .held, .stoppingLock: return false
        }
    }

    /// The trigger's DOWN edge. `now` must be monotonic and non-decreasing.
    public mutating func triggerDown(now: TimeInterval) -> Intent {
        switch phase {
        case .idle(let lastTapReleasedAt):
            // A locked session is decided up-front when: the mode is toggle, OR
            // this is the second tap of a double-tap (hold mode's gesture path).
            let isDoubleTap = lastTapReleasedAt.map { now - $0 <= config.doubleTapGap } ?? false
            let startsLocked = (mode == .toggle) || isDoubleTap
            phase = .pressed(downAt: now, startedLocked: startsLocked)
            return .start(locked: startsLocked)

        case .lockedOpen:
            // A press while locked open is the STOP tap. The stop is decided on
            // the down edge (matching how a tap should feel); the matching
            // release is swallowed in `stoppingLock`.
            phase = .stoppingLock
            return .stop

        case .pressed, .held, .stoppingLock:
            // Re-entrant down while already down (shouldn't happen given the
            // debounced edge source) — ignore.
            return .none
        }
    }

    /// The trigger's UP edge. `now` must be monotonic and non-decreasing.
    public mutating func triggerUp(now: TimeInterval) -> Intent {
        switch phase {
        case .pressed(let downAt, let startedLocked):
            let wasTap = (now - downAt) <= config.maxTapDuration
            if startedLocked {
                // Toggle mode, or the second tap of a double-tap: a quick release
                // LOCKS the session open. But if the user actually HELD the key,
                // honor that as press-to-talk (release ends the session) — so a
                // long press never strands the mic locked open.
                if wasTap {
                    phase = .lockedOpen
                    return .none
                } else {
                    phase = .idle(lastTapReleasedAt: nil)
                    return .stop
                }
            } else {
                // Hold mode, first press. A genuine hold ends on release. A quick
                // tap ends too (press-to-talk still delivers), but we remember the
                // release time so an immediate second tap reads as a double-tap
                // and re-opens locked.
                phase = .idle(lastTapReleasedAt: wasTap ? now : nil)
                return .stop
            }

        case .held:
            phase = .idle(lastTapReleasedAt: nil)
            return .stop

        case .stoppingLock:
            // The release that follows a stop tap — already handled on the down
            // edge; swallow it and return to idle.
            phase = .idle(lastTapReleasedAt: nil)
            return .none

        case .idle, .lockedOpen:
            // A stray release (locked-open holds the session across releases).
            return .none
        }
    }

    /// Esc (or any explicit cancel) while a session is active. Discards the
    /// session and returns to idle regardless of hold/lock.
    public mutating func cancel() -> Intent {
        switch phase {
        case .idle, .stoppingLock:
            return .none
        case .pressed, .held, .lockedOpen:
            phase = .idle(lastTapReleasedAt: nil)
            return .cancel
        }
    }

    /// Force the machine back to idle without emitting an intent — for when the
    /// session ends by some OTHER path (silence safety auto-stop, an agent
    /// preempting the mic, a transcription error) so the next press starts clean.
    public mutating func reset() {
        phase = .idle(lastTapReleasedAt: nil)
    }
}

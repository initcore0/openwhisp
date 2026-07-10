import Foundation

/// Pure selection logic for the rotating first-run overlay hints (MAK-25).
///
/// Foundation-only so it lives in OpenWhispCore and is unit-tested independently of
/// SwiftUI/AppKit. The overlay view owns the *live-state* suppression (never show a
/// hint during arming/finalizing/agent/refine/lock — see `shouldOfferHint`) and
/// maps the chosen hint to a dismissible line; this type owns the *which hint, and
/// whether hints are still on at all* decision, given only a session count and the
/// set of hint ids the user has dismissed.
///
/// The design:
/// - Hints are shown for roughly the first `sessionsToShow` user dictation sessions
///   of a new install, then auto-off forever. A power user isn't nagged past the
///   discovery window.
/// - Within that window one hint is shown per session, rotating through the deck by
///   session index so a user sees a different tip each time.
/// - A hint the user dismisses is never shown again (its id joins `dismissed`); the
///   rotation skips dismissed ids and lands on the next still-live hint.
/// - When every hint is dismissed, hints are effectively off even inside the window.
enum HintRotation {

    /// After this many counted user sessions, the rotating hints auto-off for good.
    /// "Roughly the first 10 sessions" per the ticket.
    static let sessionsToShow = 10

    /// Whether the rotating-hints feature is still active at this session count —
    /// i.e. we're inside the first-run discovery window. Once `sessionCount` reaches
    /// `sessionsToShow` the feature is off permanently (the auto-off rule), regardless
    /// of dismissals. `sessionCount` is 1-based (the Nth counted user session).
    ///
    /// - Parameter sessionCount: how many counted user dictation sessions have
    ///   occurred so far, INCLUDING the current one (1 on the very first session).
    static func active(sessionCount: Int, sessionsToShow: Int = sessionsToShow) -> Bool {
        sessionCount >= 1 && sessionCount <= sessionsToShow
    }

    /// The hint to show for the current session, or nil when hints are off (past the
    /// window) or nothing is left to show (every hint dismissed).
    ///
    /// Rotation: the session index picks a starting slot in the deck; from there we
    /// walk forward to the first hint whose id isn't in `dismissed`. This means a
    /// dismissed hint doesn't leave a "blank" session — the next live hint fills in —
    /// while still varying the tip session to session.
    ///
    /// - Parameters:
    ///   - sessionCount: 1-based count of counted user sessions including this one.
    ///   - dismissed: ids the user has permanently dismissed.
    ///   - hints: the deck (defaults to the shipped `TipsCatalog.hints`).
    ///   - sessionsToShow: window size (auto-off threshold).
    static func hint(
        sessionCount: Int,
        dismissed: Set<String>,
        hints: [TipsCatalog.Hint] = TipsCatalog.hints,
        sessionsToShow: Int = sessionsToShow
    ) -> TipsCatalog.Hint? {
        guard active(sessionCount: sessionCount, sessionsToShow: sessionsToShow) else { return nil }
        guard !hints.isEmpty else { return nil }

        // The still-live deck, in order, preserving rotation across dismissals.
        let live = hints.filter { !dismissed.contains($0.id) }
        guard !live.isEmpty else { return nil }

        // Rotate by (0-based) session index over the LIVE deck so each session in the
        // window surfaces a different remaining tip, wrapping if the window outlasts
        // the deck.
        let index = (sessionCount - 1) % live.count
        return live[index]
    }
}

import Foundation

/// Per-client dictation rate limiter for the Agent Bridge (plan §10 "rate limiting
/// on allowed clients", MAK-10).
///
/// Consent + the always-visible overlay stop an *unapproved* client, but an
/// **always-allowed** one could otherwise chain maximum-length `dictate` sessions
/// back-to-back — overlay-visible, yet effectively continuous listening. This adds
/// three independent belt-and-suspenders throttles on the *start* of an agent
/// dictation, keyed by the same client key consent uses:
///
/// - a **cooldown**: a minimum gap between one session's END and the next start
///   (measured from the end, not the start — a start-to-start cooldown shorter
///   than a session would never force any gap at all);
/// - a **sessions-per-hour cap**: at most `maxSessionsPerHour` starts in any
///   rolling `windowSeconds` window;
/// - a **listening-time budget**: at most `maxListeningSecondsPerHour` seconds of
///   actual mic time per window. This is the throttle that genuinely bounds
///   continuous listening — a session cap alone can't, because sessions run up to
///   `BridgeWire.DictateParams.maxTimeoutSeconds` (300s), so a modest number of
///   max-length sessions per hour already adds up to the whole hour.
///
/// Only *accepted* starts count — a call refused for busy/consent/etc. never
/// reaches ``recordStart(clientName:now:)``, so a client isn't punished for calls
/// it never got to make. Pure and Foundation-only (time is injected), so the
/// window math is unit-tested without a clock.
public struct AgentRateLimiter: Equatable, Sendable {

    /// Minimum seconds between the END of one accepted `dictate` session and the
    /// next start from the same client. A start is refused until this long after
    /// the client's previous session ended (or started, if its end was never
    /// recorded).
    public var cooldownSeconds: TimeInterval
    /// Maximum accepted `dictate` starts from one client within any rolling
    /// `windowSeconds` window. Zero disables the per-window cap.
    public var maxSessionsPerHour: Int
    /// Maximum seconds of recorded mic time for one client within any rolling
    /// `windowSeconds` window. Zero disables the listening budget.
    public var maxListeningSecondsPerHour: TimeInterval
    /// The rolling window the caps are measured over (default one hour).
    public var windowSeconds: TimeInterval

    /// One accepted dictation: its start, and — once ``recordEnd`` runs — how many
    /// seconds the mic was actually open. Zero until the end is recorded.
    private struct Session: Equatable, Sendable {
        var start: Date
        var seconds: TimeInterval = 0
        /// When this session last held the mic: its end if recorded, else its
        /// start. The cooldown runs from here.
        var lastActivity: Date { start.addingTimeInterval(seconds) }
    }

    /// Accepted sessions per client, oldest first. Pruned to the window on every
    /// check/record so it can't grow without bound for a long-lived client.
    private var sessions: [String: [Session]] = [:]

    public init(
        cooldownSeconds: TimeInterval = 3,
        maxSessionsPerHour: Int = 30,
        maxListeningSecondsPerHour: TimeInterval = 600,
        windowSeconds: TimeInterval = 3600
    ) {
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.maxSessionsPerHour = max(0, maxSessionsPerHour)
        self.maxListeningSecondsPerHour = max(0, maxListeningSecondsPerHour)
        self.windowSeconds = max(1, windowSeconds)
    }

    /// The outcome of checking whether a client may start a dictation now.
    public enum Decision: Equatable {
        /// Allowed — the caller should proceed and then ``recordStart``.
        case allow
        /// Refused; `retryAfter` is the wait until the client would next be
        /// allowed (the max of the cooldown remainder and, for a full session or
        /// listening window, the time until enough of it ages out).
        case throttled(retryAfter: TimeInterval)
    }

    /// Whether `clientName` may start a dictation at `now`, without recording it.
    /// Pure — call ``recordStart(clientName:now:)`` after a start is accepted.
    public func check(clientName: String, now: Date) -> Decision {
        let recent = pruned(sessions[clientName] ?? [], now: now)

        var retryAfter: TimeInterval = 0

        // Cooldown: gap since the most recent session last held the mic. This is
        // the one throttle that legitimately keys on `lastActivity` (the session's
        // end), so it consults `recent` — pruned on that same clock.
        if let last = recent.last {
            let sinceLast = now.timeIntervalSince(last.lastActivity)
            if sinceLast < cooldownSeconds {
                retryAfter = max(retryAfter, cooldownSeconds - sinceLast)
            }
        }

        // The cap and the budget are both keyed on a session's `start` (when the
        // slot was claimed / the mic-time began accruing), so they must decide
        // membership on that same clock — not on `lastActivity`, which `pruned()`
        // uses for the cooldown. A "straddling" session whose `start` predates the
        // window but whose `lastActivity` keeps it in `recent` is NOT in-window for
        // these two: counting it while flooring its age-out at 0 would let new
        // in-window starts pile up unbounded behind a stale `oldest` (MAK-31).
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let inWindow = recent.filter { $0.start > cutoff }

        // Per-window cap: full window → wait for the oldest *in-window* start to
        // age out. Because membership and age-out share the `start` clock, the
        // oldest in-window start is strictly newer than `cutoff`, so its age-out is
        // always strictly positive — no floor needed, and the invariant (at most
        // `maxSessionsPerHour` in-window starts) holds by construction.
        if maxSessionsPerHour > 0, inWindow.count >= maxSessionsPerHour, let oldest = inWindow.first {
            let ageOut = windowSeconds - now.timeIntervalSince(oldest.start)
            retryAfter = max(retryAfter, ageOut)
        }

        // Listening budget: total recorded mic time from in-window starts. When
        // exhausted, wait until enough of the oldest of them age out to get back
        // under it. Same clock as the cap: only sessions that started in the window
        // count, so every `wait` below is derived from an in-window start and is
        // strictly positive.
        if maxListeningSecondsPerHour > 0 {
            let total = inWindow.reduce(0) { $0 + $1.seconds }
            if total >= maxListeningSecondsPerHour {
                var freed: TimeInterval = 0
                var wait: TimeInterval = 0
                for session in inWindow {
                    wait = windowSeconds - now.timeIntervalSince(session.start)
                    freed += session.seconds
                    if total - freed < maxListeningSecondsPerHour { break }
                }
                retryAfter = max(retryAfter, wait)
            }
        }

        return retryAfter > 0 ? .throttled(retryAfter: retryAfter) : .allow
    }

    /// Record an accepted start for `clientName` at `now`. Call only after a start
    /// is actually accepted, so refused calls don't consume the client's budget.
    public mutating func recordStart(clientName: String, now: Date) {
        var recent = pruned(sessions[clientName] ?? [], now: now)
        recent.append(Session(start: now))
        sessions[clientName] = recent
    }

    /// Record that `clientName`'s most recent session ended at `now`, charging its
    /// duration against the listening budget and restarting the cooldown from the
    /// end. Sessions are serialized by the host's busy guard, so "most recent" is
    /// always the one that just ended. A missing entry (e.g. after ``forget``) is
    /// a no-op.
    public mutating func recordEnd(clientName: String, now: Date) {
        guard var recent = sessions[clientName], let last = recent.indices.last else { return }
        recent[last].seconds = max(0, now.timeIntervalSince(recent[last].start))
        sessions[clientName] = recent
    }

    /// Drop a client's history entirely — used when its consent is revoked, so a
    /// re-approved client starts with a clean budget.
    public mutating func forget(clientName: String) {
        sessions.removeValue(forKey: clientName)
    }

    /// Number of accepted starts for a client that fall within the current window
    /// *by start time* — i.e. exactly the set the per-window cap counts (for tests
    /// / a future settings display). Keys on `start`, matching the cap, so a
    /// straddling session whose start has aged past the window no longer inflates
    /// the count even while its `lastActivity` still binds the cooldown.
    public func sessionCount(clientName: String, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        return pruned(sessions[clientName] ?? [], now: now).filter { $0.start > cutoff }.count
    }

    /// Drop sessions that can no longer bind the *cooldown* — those whose
    /// `lastActivity` (session end, the cooldown clock) is older than the window
    /// (or the cooldown horizon, whichever reaches further back). This keys on
    /// `lastActivity`, so the survivors are exactly the set the cooldown consults;
    /// `check()` re-derives the cap/budget's in-window set from `start` on top of
    /// this, since those two throttles key on a different clock. Kept
    /// sorted-ascending by construction (we only append at `now`), so the surviving
    /// suffix is contiguous.
    private func pruned(_ recent: [Session], now: Date) -> [Session] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        // Also honor the cooldown horizon: even past the window, the immediately
        // preceding session could still bind the cooldown. windowSeconds >= cooldown
        // in every sane config, so the window cutoff already covers it; this is
        // just defensive if a caller sets a cooldown longer than the window.
        let horizon = min(cutoff, now.addingTimeInterval(-cooldownSeconds))
        return recent.filter { $0.lastActivity > horizon }
    }
}

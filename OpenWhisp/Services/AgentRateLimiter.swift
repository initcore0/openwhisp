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

        // Cooldown: gap since the most recent session last held the mic.
        if let last = recent.last {
            let sinceLast = now.timeIntervalSince(last.lastActivity)
            if sinceLast < cooldownSeconds {
                retryAfter = max(retryAfter, cooldownSeconds - sinceLast)
            }
        }

        // Per-window cap: full window → wait for the oldest start to age out.
        // Floored at 0: a long session can survive pruning on its `lastActivity`
        // (the cooldown clock) while its `start` (the cap clock) already predates
        // the window, which would otherwise make this age-out negative.
        if maxSessionsPerHour > 0, recent.count >= maxSessionsPerHour, let oldest = recent.first {
            let ageOut = max(0, windowSeconds - now.timeIntervalSince(oldest.start))
            retryAfter = max(retryAfter, ageOut)
        }

        // Listening budget: total recorded mic time in the window. When exhausted,
        // wait until enough of the oldest sessions age out to get back under it.
        if maxListeningSecondsPerHour > 0 {
            let total = recent.reduce(0) { $0 + $1.seconds }
            if total >= maxListeningSecondsPerHour {
                var freed: TimeInterval = 0
                var wait: TimeInterval = 0
                for session in recent {
                    // Floored at 0 for the same reason as the cap above: a session
                    // kept alive by its `lastActivity` can have a `start` that
                    // already predates the window.
                    wait = max(0, windowSeconds - now.timeIntervalSince(session.start))
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

    /// Accepted-start count for a client within the current window (for tests / a
    /// future settings display).
    public func sessionCount(clientName: String, now: Date) -> Int {
        pruned(sessions[clientName] ?? [], now: now).count
    }

    /// Drop sessions whose start is older than the window (they can no longer bind
    /// the cooldown, the cap, or the budget — a session's length is bounded far
    /// below any sane window). Kept sorted-ascending by construction (we only
    /// append at `now`), so the surviving suffix is contiguous.
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

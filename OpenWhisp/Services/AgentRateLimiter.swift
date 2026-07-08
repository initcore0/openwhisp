import Foundation

/// Per-client dictation rate limiter for the Agent Bridge (plan §10 "rate limiting
/// on allowed clients", MAK-10).
///
/// Consent + the always-visible overlay stop an *unapproved* client, but an
/// **always-allowed** one could otherwise chain maximum-length `dictate` sessions
/// back-to-back — overlay-visible, yet effectively continuous listening. This adds
/// two independent belt-and-suspenders throttles on the *start* of an agent
/// dictation, keyed by the same client key consent uses:
///
/// - a **cooldown**: a minimum gap between one session's start and the next;
/// - a **sessions-per-hour cap**: at most `maxSessionsPerHour` starts in any
///   rolling 60-minute window.
///
/// Only *accepted* starts count — a call refused for busy/consent/etc. never
/// reaches ``record(clientName:now:)``, so a client isn't punished for calls it
/// never got to make. Pure and Foundation-only (time is injected), so the window
/// math is unit-tested without a clock.
public struct AgentRateLimiter: Equatable, Sendable {

    /// Minimum seconds between two accepted `dictate` starts from one client.
    /// A start is refused until this long after the client's previous start.
    public var cooldownSeconds: TimeInterval
    /// Maximum accepted `dictate` starts from one client within any rolling
    /// `windowSeconds` window. Zero disables the per-window cap (cooldown only).
    public var maxSessionsPerHour: Int
    /// The rolling window the cap is measured over (default one hour).
    public var windowSeconds: TimeInterval

    /// Accepted-start timestamps per client, newest last. Pruned to the window on
    /// every check/record so it can't grow without bound for a long-lived client.
    private var starts: [String: [Date]] = [:]

    public init(
        cooldownSeconds: TimeInterval = 3,
        maxSessionsPerHour: Int = 30,
        windowSeconds: TimeInterval = 3600
    ) {
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.maxSessionsPerHour = max(0, maxSessionsPerHour)
        self.windowSeconds = max(1, windowSeconds)
    }

    /// The outcome of checking whether a client may start a dictation now.
    public enum Decision: Equatable {
        /// Allowed — the caller should proceed and then ``record`` the start.
        case allow
        /// Refused; `retryAfter` is the wait until the client would next be
        /// allowed (the max of the cooldown remainder and, if the window is full,
        /// the time until its oldest start ages out).
        case throttled(retryAfter: TimeInterval)
    }

    /// Whether `clientName` may start a dictation at `now`, without recording it.
    /// Pure — call ``record(clientName:now:)`` after a start is actually accepted.
    public func check(clientName: String, now: Date) -> Decision {
        let recent = pruned(starts[clientName] ?? [], now: now)

        var retryAfter: TimeInterval = 0

        // Cooldown: gap since the most recent start.
        if let last = recent.last {
            let sinceLast = now.timeIntervalSince(last)
            if sinceLast < cooldownSeconds {
                retryAfter = max(retryAfter, cooldownSeconds - sinceLast)
            }
        }

        // Per-window cap: full window → wait for the oldest start to age out.
        if maxSessionsPerHour > 0, recent.count >= maxSessionsPerHour, let oldest = recent.first {
            let ageOut = windowSeconds - now.timeIntervalSince(oldest)
            retryAfter = max(retryAfter, ageOut)
        }

        return retryAfter > 0 ? .throttled(retryAfter: retryAfter) : .allow
    }

    /// Record an accepted start for `clientName` at `now`. Call only after a start
    /// is actually accepted, so refused calls don't consume the client's budget.
    public mutating func record(clientName: String, now: Date) {
        var recent = pruned(starts[clientName] ?? [], now: now)
        recent.append(now)
        starts[clientName] = recent
    }

    /// Drop a client's history entirely — used when its consent is revoked, so a
    /// re-approved client starts with a clean budget.
    public mutating func forget(clientName: String) {
        starts.removeValue(forKey: clientName)
    }

    /// Accepted-start count for a client within the current window (for tests / a
    /// future settings display).
    public func sessionCount(clientName: String, now: Date) -> Int {
        pruned(starts[clientName] ?? [], now: now).count
    }

    /// Drop timestamps older than the window (they can no longer bind either the
    /// cooldown or the cap). Kept sorted-ascending by construction (we only append
    /// `now`), so the surviving suffix is contiguous.
    private func pruned(_ dates: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        // Also honor the cooldown horizon: even past the window, the immediately
        // preceding start could still bind the cooldown. windowSeconds >= cooldown
        // in every sane config, so the window cutoff already covers it; this is
        // just defensive if a caller sets a cooldown longer than the window.
        let horizon = min(cutoff, now.addingTimeInterval(-cooldownSeconds))
        return dates.filter { $0 > horizon }
    }
}

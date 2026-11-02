import Foundation
import OpenWhispCore

/// How long ``BridgeClient`` waits on the app before giving up with
/// ``BridgeClient/ClientError/timedOut(method:seconds:)``.
///
/// Every bridge verb on the app side hops to the main thread before it answers,
/// so a wedged app (model load, modal dialog, beachball) used to leave the CLI
/// and MCP adapter parked in `read()` forever — including `openwhisp status`, the
/// liveness probe that exists to detect exactly that case. Each call now gets a
/// response deadline sized to what the verb can legitimately take.
public enum BridgeTimeouts {

    /// `connect()` deadline. On macOS an AF_UNIX connect fails fast even with a
    /// full backlog (ECONNREFUSED), so this is a backstop, not the main guard.
    public static let connectSeconds: TimeInterval = 3

    /// Per-`write()` deadline (SO_SNDTIMEO). Requests are small; a peer that
    /// won't drain a few KB in this long is wedged.
    public static let writeSeconds: TimeInterval = 10

    /// Verbs that never wait on the user: `bridge.hello`, `status`,
    /// `dictate.stop`, `dictate.cancel`. One main-thread hop on the app side.
    public static let controlSeconds: TimeInterval = 15

    /// The app's consent window can hold a guarded verb this long before the
    /// work even starts (AgentConsentWindow's timeout).
    public static let consentWindowSeconds: TimeInterval = 60

    /// Headroom on top of a verb's own budget: final transcription after a
    /// dictate ends, main-thread hops, scheduling slop.
    public static let slackSeconds: TimeInterval = 30

    /// Budget for a local-LLM refine (no app-side cap exists to derive it from).
    public static let refineWorkSeconds: TimeInterval = 300

    /// Budget for transcribing a long local file.
    public static let transcribeFileWorkSeconds: TimeInterval = 3600

    /// The response deadline for one call. `dictateTimeoutSeconds` is the
    /// request's own `timeoutSeconds` (nil → the app default); it is clamped the
    /// same way the app clamps it, so the client never gives up before the app
    /// would.
    public static func responseDeadline(method: String, dictateTimeoutSeconds: Int?) -> TimeInterval {
        guard let m = BridgeWire.Method(rawValue: method) else {
            // Unknown to this build: assume it may be consent-gated.
            return consentWindowSeconds + slackSeconds
        }
        switch m {
        case .hello, .status, .dictateStop, .dictateCancel:
            return controlSeconds
        case .dictate:
            let t = BridgeRouter.resolvedTimeoutSeconds(dictateTimeoutSeconds)
            return consentWindowSeconds + TimeInterval(t) + slackSeconds
        case .refine:
            return consentWindowSeconds + refineWorkSeconds + slackSeconds
        case .transcribeFile:
            return consentWindowSeconds + transcribeFileWorkSeconds + slackSeconds
        case .historyList, .syncManifest, .syncPull, .syncPush:
            return consentWindowSeconds + slackSeconds
        }
    }
}

import Foundation

/// Whether warming a provider means WAITING for a local server, and what "ready"
/// means when it doesn't (plugin spike v4).
///
/// ## Why this is a resolver and not three guards inside AppState
///
/// The meme plugin's report was "the first two Generates fail with a network error".
/// The cause was that the warm had no readiness signal: `warmLlamaServerIfPossible`
/// discarded `ensureRunning`'s completion — the one thing that actually knows the
/// server answered its `/health` poll — and the plugin slept a guessed 2.5 seconds
/// instead. Fixing that means a caller can now ask "is it ready?", and the answer
/// depends on WHICH provider is resolved:
///
/// * **bundled** — there is a local llama-server, so readiness is its health check.
/// * **anything else** (a cloud or remote endpoint) — there is no local server to
///   start, so it is ready by definition. Gating a cloud provider on a llama-server
///   that will never launch would leave "Preparing model…" on screen forever, which
///   is the stuck-state bug wearing a different hat.
/// * **bundled but not installed / not enabled** — genuinely not ready, and the
///   caller must say so rather than firing a request into nothing.
///
/// That decision is pure policy, so it lives here where `swift test` pins it, and
/// AppState keeps only the engine call (MAK-32 ratchet: new logic goes to core, not
/// into the god object).
public enum LLMWarmReadiness {

    /// What a caller should do to warm `provider`.
    public enum Decision: Equatable, Sendable {
        /// Start the local server and report its health-check result.
        case awaitLocalServer
        /// Nothing to start — report ready immediately.
        case alreadyReady
        /// Nothing to start and it will never be ready; report not-ready.
        case unavailable
    }

    /// Decide how to warm.
    ///
    /// `isExplicit` marks a caller that resolved its OWN provider (the MAK-53 split a
    /// plugin or the Scratchpad makes) rather than inheriting the global cleanup one.
    /// That distinction is why `cleanupEnabled` gates only the implicit case: a
    /// surface deliberately resolved to the bundled provider must still warm even when
    /// Settings → Cleanup is switched off or pointed elsewhere.
    public static func decide(
        provider: String,
        isExplicit: Bool,
        modelInstalled: Bool,
        cleanupEnabled: Bool
    ) -> Decision {
        guard provider == "bundled" else { return .alreadyReady }
        guard modelInstalled else { return .unavailable }
        guard isExplicit || cleanupEnabled else { return .unavailable }
        return .awaitLocalServer
    }
}

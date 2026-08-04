import Foundation

/// The AppState half of the LLM warm path (plugin spike v4).
///
/// Lives outside `AppState.swift` deliberately: MAK-32's ratchet says new AppState
/// logic goes into core or an extension rather than growing the god object. The
/// *policy* — which providers need a local server at all — is the pure
/// `LLMWarmReadiness` resolver next door, pinned by `swift test`; this file holds only
/// the part that must touch the engine.
extension AppState {

    /// Start the bundled llama-server when it is the active, enabled, downloaded
    /// provider. Idempotent (the engine no-ops if already healthy). Which providers
    /// warm, and why an explicitly-resolved one bypasses the cleanup toggle (MAK-53),
    /// is decided by `LLMWarmReadiness.decide` — see it for the rules.
    ///
    /// `completion` (v4) reports REAL readiness. `ensureRunning` polls llama-server's
    /// `/health` and calls back only once it answers, so a caller can gate a button on
    /// "the model can actually take a request" instead of guessing a duration — which
    /// is exactly what the meme plugin was doing when its first two Generates failed
    /// with a raw network error. Passing nil keeps the historic fire-and-forget
    /// behaviour for the callers that don't wait.
    func warmLlamaServerIfPossible(
        provider explicitProvider: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let decision = LLMWarmReadiness.decide(
            provider: explicitProvider ?? llmProvider,
            isExplicit: explicitProvider != nil,
            modelInstalled: bundledLLMModelInstalled,
            cleanupEnabled: openAIEnhancementEnabled)

        guard decision == .awaitLocalServer else {
            completion?(decision == .alreadyReady)
            return
        }

        let engine = ensureLlamaEngine()
        // Shorter idle teardown when a whisper-server is also resident, to relieve
        // dual-engine memory pressure sooner (small-RAM Macs run both models).
        engine.idleTimeout = whisperServerResident ? 30 : 90
        engine.ensureRunning(modelPath: selectedLLMModelPath()) { result in
            guard let completion else { return }
            // `ensureRunning` completes off the main thread; callers are main-actor.
            Task { @MainActor in completion((try? result.get()) != nil) }
        }
    }
}

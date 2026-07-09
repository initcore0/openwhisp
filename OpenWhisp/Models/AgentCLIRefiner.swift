import Foundation

/// App-side implementation of the `AsyncTextRefiner` seam (MAK-15) that runs the
/// whole-text refine step through a locally-installed **agent CLI** (`claude -p …`,
/// `codex exec …`, or a custom stdin→stdout command) instead of an
/// OpenAI-compatible HTTP endpoint (MAK-44).
///
/// It is the app-layer glue that lets the user pick "Agent CLI (Claude / Codex)" as
/// their AI-cleanup provider: `makeWholeTextRefiner()` returns this instead of
/// `OpenAIRefiner` when `llmProvider == EnhancementProvider.agentCLIID`, so it drops
/// straight into the same `AIPostProcessor` chain and the same `completeFinalText`
/// orchestration (status UI, session guards) with no other change.
///
/// Fail-open by contract: `AgentCLIRunner.run` already resolves every failure
/// (missing CLI, non-zero exit, timeout, empty output) back to the ORIGINAL
/// transcript — the user's words are never dropped. This refiner therefore never
/// throws; a "failed" refine simply returns the input, which the `AIPostProcessor`
/// stage treats as a no-op. (Contrast `OpenAIRefiner`, which throws so the stage
/// falls back — here the *runner* already did the fallback for us.)
///
/// `AgentCLIRunner.run` is a blocking `Process` spawn, so `refine` hops it onto a
/// detached background task rather than blocking the caller's actor. The captured
/// `Config` is a value type, so the closure is safe across the concurrency boundary.
struct AgentCLIRefiner: AsyncTextRefiner, @unchecked Sendable {
    /// The resolved provider config (executable + fixed args + timeout). The
    /// transcript is fed on stdin by the runner, never templated into this.
    let config: AgentCLIProvider.Config

    func refine(_ text: String, context: PostProcessContext) async throws -> String {
        let config = self.config
        return await Task.detached(priority: .userInitiated) {
            // Runner is fail-open: returns the refined stdout on a clean success,
            // otherwise the original `text`. Never nil, never throws.
            AgentCLIRunner.run(text, config: config)
        }.value
    }
}

import Foundation

/// Context passed to a post-processor so it can adapt behavior (per-app modes,
/// vocabulary, language, etc. will hang off this as the roadmap grows).
struct PostProcessContext {
    /// BCP-47 / whisper language code for the session ("auto", "en", "ru", ...).
    var language: String
    /// Bundle identifier of the app text is being inserted into, if known.
    var targetBundleID: String?
    /// Whether this is a live (per-chunk) transform vs a whole-utterance final.
    var isLiveChunk: Bool
}

/// A stage that transforms transcribed text before it is inserted.
///
/// This is the seam that lets rule-based formatting, OpenAI, and (later) a local
/// LLM all be composed uniformly. Implementations must be safe to call
/// off the main actor and must never throw for "no change" — return the input.
protocol PostProcessor: Sendable {
    /// Transform `text`. Return the input unchanged if there's nothing to do.
    /// Throwing is reserved for genuine failures (e.g. a network backend);
    /// callers are expected to fall back to the prior text on error.
    func process(_ text: String, context: PostProcessContext) async throws -> String
}

/// Runs several processors in order, threading the output of each into the next.
/// A stage that throws is skipped (its input is carried forward) so one failing
/// optional stage can't break the whole chain.
struct PostProcessorChain: PostProcessor {
    let stages: [PostProcessor]

    init(_ stages: [PostProcessor]) {
        self.stages = stages
    }

    func process(_ text: String, context: PostProcessContext) async throws -> String {
        var current = text
        for stage in stages {
            do {
                current = try await stage.process(current, context: context)
            } catch {
                // Skip a failing stage rather than aborting the chain.
                continue
            }
        }
        return current
    }
}

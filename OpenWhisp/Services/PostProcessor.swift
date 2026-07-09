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

// MARK: - AI (LLM) stage seam

/// The network-bound LLM refinement step, expressed as a protocol so `OpenWhispCore`
/// stays Foundation-only and network-free.
///
/// The app implements this over `OpenAITranslationService` (see
/// `AppState.OpenAIRefiner`); core and its tests use a stub. This is the seam the
/// ticket (MAK-15) calls for: `AIPostProcessor` composes into a `PostProcessorChain`
/// like every other stage, but the concrete LLM call lives in the app layer.
///
/// `refine` mirrors the exact contract of `AppState`'s current AI step: given the
/// already-locally-cleaned final text, return the refined text (or throw on
/// failure — callers fall back to the input).
protocol AsyncTextRefiner: Sendable {
    /// Refine `text`. Throw on a genuine failure; the caller falls back to `text`.
    func refine(_ text: String, context: PostProcessContext) async throws -> String
}

/// Wraps an `AsyncTextRefiner` behind the `PostProcessor` protocol so the LLM
/// pass drops into the same ordered chain as the local stages.
///
/// It reproduces `AppState.completeFinalText`'s whole-text AI behavior EXACTLY:
///   1. Empty input is passed straight through (the app never runs the LLM on an
///      empty final transcript — it inserts nothing and finishes the session).
///   2. Otherwise the refiner is called. Its output is re-run through the local
///      cleaner (`reclean`, a NON-final `TranscriptCleaner.clean`) — matching the
///      `cleaned = self.postProcess(processedText)` line.
///   3. If the refiner throws, OR the re-cleaned output is empty, the stage falls
///      back to its INPUT (the pre-AI locally-cleaned text) — matching both the
///      `.failure` branch and the `guard !cleaned.isEmpty` empty-LLM-output branch.
///
/// The stage itself never throws: a refiner failure is an internal fallback, not a
/// chain-aborting error, so the whole-utterance final still lands the local text.
struct AIPostProcessor: PostProcessor {
    /// The LLM step. Nil = the AI stage is disabled for this session (the chain
    /// then behaves exactly like the local-only pipeline).
    let refiner: AsyncTextRefiner?
    /// Local re-clean applied to the refiner's output, mirroring the non-final
    /// `postProcess(processedText)` the app runs on the LLM result. Defaults to a
    /// no-op so a bare `AIPostProcessor(refiner:)` is still meaningful in isolation.
    let reclean: @Sendable (String) -> String

    init(
        refiner: AsyncTextRefiner?,
        reclean: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.refiner = refiner
        self.reclean = reclean
    }

    func process(_ text: String, context: PostProcessContext) async throws -> String {
        // No refiner configured → the AI stage is a pass-through (local pipeline).
        guard let refiner else { return text }
        // The app never runs the LLM on an empty final transcript; mirror that so a
        // stray refiner can't turn "" into content.
        guard !text.isEmpty else { return text }
        do {
            let refined = try await refiner.refine(text, context: context)
            let cleaned = reclean(refined)
            // Empty LLM output (after re-clean) falls back to the pre-AI text,
            // exactly like `guard !cleaned.isEmpty` in completeFinalText.
            return cleaned.isEmpty ? text : cleaned
        } catch {
            // Refiner failure → keep the local text (the app's `.failure` branch).
            return text
        }
    }
}

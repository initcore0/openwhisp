import Foundation

/// App-side implementation of the `AsyncTextRefiner` seam (MAK-15).
///
/// `OpenWhispCore` defines `AsyncTextRefiner` / `AIPostProcessor` but is
/// deliberately network-free — it must NOT reference `OpenAITranslationService`.
/// This adapter lives in the app layer and wraps that (completion-based,
/// URLSession-backed) service behind the async protocol, so the real LLM step can
/// drop into a `PostProcessorChain` (`VocabularySubstitutor → SmartFormatter →
/// AIPostProcessor`) without pulling networking into core.
///
/// It reproduces the parameters of `AppState.completeFinalText`'s whole-text AI
/// call verbatim (mode, target language, endpoint, model). The engine lifecycle
/// (`ensureBundledLLMReady`), session-ID guards, and status UI stay in AppState —
/// this adapter is only the text-in/text-out transform the chain composes.
///
/// This is a value type capturing a snapshot of the session's LLM settings, so it
/// is safe to hand to the (off-main-actor) chain. It throws on failure; the
/// `AIPostProcessor` stage falls back to the pre-AI text, exactly as the old path
/// did on a `.failure`.
///
/// `@unchecked Sendable`: the only reference-type field is
/// `OpenAITranslationService`, which is stateless (no stored properties — it just
/// makes URLSession calls), so sharing it across the concurrency boundary is safe.
struct OpenAIRefiner: AsyncTextRefiner, @unchecked Sendable {
    let service: OpenAITranslationService
    let mode: String
    let targetLanguage: String
    let endpoint: LLMEndpoint
    let model: String

    func refine(_ text: String, context: PostProcessContext) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.processFinalText(
                text: text,
                mode: mode,
                targetLanguage: targetLanguage,
                endpoint: endpoint,
                model: model
            ) { result in
                continuation.resume(with: result)
            }
        }
    }
}

import Foundation

/// Minimal per-purpose engine routing (MAK-69).
///
/// This is deliberately NOT a general router. The engine-capability model reduced
/// the routing problem to a single honest case: **translation**. Every other
/// capability is either offered-iff-honored on the current engine (vocabulary,
/// partials) or gated at pick-time (language), so there is nothing to reroute.
/// Once MAK-71 landed batch vocabulary biasing on Parakeet, translation is the
/// only purpose where "the engine the user is on can't do the thing they asked"
/// still happens (Parakeet / Apple Speech / SpeechAnalyzer are ASR-only).
///
/// It answers ONE pure question — "for a translation request while on engine X,
/// what should happen?" — and leaves the act of swapping engines to the caller.
/// Keeping the decision pure (no engine instances, no model loads) is what makes
/// it `swift test`-able and keeps the "which engine" knowledge out of AppState.
public enum EnginePurposeRouter {
    /// The routing decision for a translate-to-English request.
    public enum TranslationRouting: Equatable {
        /// The current engine already translates — proceed on it, no change.
        case useCurrent
        /// The current engine can't translate. `to` is a translation-capable
        /// engine to route the request to; `disclosure` is the user-facing
        /// sentence explaining the switch (never route silently — that would hide
        /// which engine actually produced the output).
        case reroute(to: String, disclosure: String)
        /// The current engine can't translate and no capable engine is available
        /// to fall back to. The caller must refuse the translate request and keep
        /// transcribing in the spoken language (the LanguageResolver suppression
        /// rule); `reason` is the user-facing explanation.
        case unavailable(reason: String)
    }

    /// Preferred translation-capable engines, best-first. Both whisper engines
    /// translate; WhisperKit is the app default (CoreML/ANE), so it leads.
    public static let translationCapablePreference: [String] = [
        EngineCapabilities.whisperKit,
        EngineCapabilities.whisperCpp,
    ]

    /// Decide what to do when the user asks to translate to English while on
    /// `currentEngine`.
    ///
    /// - Parameters:
    ///   - currentEngine: the active transcription engine id.
    ///   - availableEngines: engine ids the user actually has available to route
    ///     to (e.g. installed/enabled). Defaults to the whole known set; callers
    ///     that track installation should pass the real availability so we never
    ///     recommend an engine the user can't select.
    public static func routeTranslation(
        currentEngine: String,
        availableEngines: Set<String> = Set(EngineCapabilities.allEngineIDs)
    ) -> TranslationRouting {
        if EngineCapabilities.capabilities(for: currentEngine).translation {
            return .useCurrent
        }
        let currentName = EngineCapabilities.displayName(transcriptionEngine: currentEngine)
        guard let target = translationCapablePreference.first(where: {
            availableEngines.contains($0) && EngineCapabilities.capabilities(for: $0).translation
        }) else {
            return .unavailable(reason:
                "\(currentName) can't translate speech to English, and no translation-capable engine is available. Transcribing in the spoken language instead.")
        }
        let targetName = EngineCapabilities.displayName(transcriptionEngine: target)
        return .reroute(to: target, disclosure:
            "\(currentName) can't translate speech to English, so this request uses \(targetName).")
    }
}

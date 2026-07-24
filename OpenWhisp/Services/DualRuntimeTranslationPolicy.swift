import Foundation

/// Should a dictation session run the DUAL-RUNTIME translation path?
///
/// The dual path exists for one gap in the capability matrix: a user who wants
/// their speech translated to English while dictating with a fast streaming
/// engine that *cannot itself translate* (Parakeet, Apple Speech — ASR-only, see
/// `EngineCapabilities.translation`). Historically that combination silently
/// gated translation OFF (`LanguageResolver.effectiveTranslateToEnglish` returns
/// false on those engines). The dual path recovers it: the fast engine still
/// drives the live on-screen preview, while the SAME audio is teed to a
/// whisper-family file engine running `task=translate`, and the session's FINAL
/// pasted text becomes that English translation.
///
/// This is the single, pure, unit-tested predicate that decides whether to arm
/// that path — so the decision is a capability question (never an engine-name
/// check at the call site, the rule this repo keeps re-learning):
///
///   1. the user asked to translate (`translateToEnglish`),
///   2. the spoken language is NOT already English (translating en→en is a no-op),
///   3. the active streaming engine CANNOT translate on its own
///      (`EngineCapabilities.translation == false`) — otherwise the normal
///      single-engine translate path already handles it,
///   4. that engine DOES provide an audio tap we can tee from
///      (`EngineCapabilities.providesAudioTap`) — without frames to forward there
///      is nothing to translate, and we must never open a second mic.
///
/// When every clause holds, the caller attaches the tee (engine audio →
/// `TranslationChunker` → `LiveTranslationCoordinator`) and swaps the final text
/// for the drained translation. When any clause fails the session behaves exactly
/// as before (either normal translate, or transcript-in-spoken-language).
public enum DualRuntimeTranslationPolicy {

    /// Whether the dual-runtime translate path should run for this session.
    public static func shouldRun(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String
    ) -> Bool {
        guard translateToEnglish else { return false }
        // English source → nothing to translate. "auto" is not English (the
        // speaker may be dictating a non-English language), so it qualifies.
        if isEnglish(language) { return false }
        let caps = EngineCapabilities.capabilities(for: transcriptionEngine)
        // The engine can translate itself → the normal path owns it, no tee.
        if caps.translation { return false }
        // No frames to tee → nothing the dual path can act on.
        guard caps.providesAudioTap else { return false }
        return true
    }

    /// Whether the UI should OFFER "Translate to English" for this engine at
    /// all: either the engine translates itself (whisper family) or the dual
    /// path can cover it (ASR-only + audio tap). The single gate for every
    /// offer surface (menu bar, Dictation pane) so they can never disagree.
    public static func translationOffered(transcriptionEngine: String) -> Bool {
        LanguageResolver.supportsTranslation(transcriptionEngine: transcriptionEngine)
            || EngineCapabilities.capabilities(for: transcriptionEngine).providesAudioTap
    }

    /// Whether the language code names English (so translating is a no-op).
    /// Uses the same base-code stripping as the Parakeet language gate so
    /// regional tags ("en-US") count.
    private static func isEnglish(_ language: String) -> Bool {
        ParakeetLanguageHint.baseCode(from: language) == "en"
    }
}

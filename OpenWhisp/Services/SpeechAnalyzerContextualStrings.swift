import Foundation

/// Prepares the bias terms handed to SpeechAnalyzer's contextual-strings channel
/// (`AnalysisContext.contextualStrings`, macOS 26 SDK) from the whisper-shaped
/// `prompt` string the transcription protocol carries (MAK-84).
///
/// The protocol passes ONE comma-joined `initial_prompt` (whisper.cpp-shaped);
/// SpeechAnalyzer's contextual biasing wants the opposite — a *list* of discrete
/// phrases to weight toward. So the terms are joined upstream
/// (`AppState.effectiveWhisperPrompt`) and split back apart here via the shared
/// `ParakeetVocabularyPrompt` splitter, then capped.
///
/// This is deliberately pure (no Speech/AVFoundation symbols) and lives in
/// `OpenWhispCore` so `swift test` covers the term-preparation logic without the
/// macOS-26 SDK. `SpeechAnalyzerBridge.makeContext` wraps the result in an
/// `AnalysisContext` behind the `#if compiler(>=6.2)` gate.
public enum SpeechAnalyzerContextualStrings {
    /// Cap on how many bias phrases we hand the analyzer. A vocabulary this long
    /// stops being a bias hint and becomes a decode cost; Apple's guidance is a
    /// modest phrase list, not a dictionary. First-N wins (the user's own
    /// vocabulary is prepended upstream, ahead of harvested screen-context terms).
    public static let maxTerms = 50

    /// Split `prompt` into discrete bias phrases (via `ParakeetVocabularyPrompt`,
    /// which drops <3 / >60-char terms and case-insensitively dedups) and cap the
    /// count. Empty prompt → empty list → the plain, unbiased path.
    public static func terms(from prompt: String) -> [String] {
        Array(ParakeetVocabularyPrompt.terms(from: prompt).prefix(maxTerms))
    }
}

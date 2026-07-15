import Foundation

/// What each transcription engine can actually do.
///
/// The engines are not interchangeable, and pretending otherwise is a recurring
/// source of user-visible bugs: a setting is offered, the user turns it on, and
/// the engine silently discards it. That has now happened twice — translation on
/// Parakeet (#175) and custom vocabulary on Parakeet/WhisperKit/Apple Speech
/// (MAK-70) — because capability lived as ad-hoc engine-name comparisons scattered
/// across call sites instead of as one thing to ask.
///
/// This is the single place to ask "can engine X do Y?". It is deliberately pure
/// (no AppKit, no engine instances) so the UI, the pipeline, and `swift test` can
/// all consult the same answers.
///
/// MAK-69 will move these declarations onto the engines themselves and add a
/// router; until then, keeping the knowledge here — rather than inline at each
/// call site — is what makes that migration a refactor instead of another hunt.
public enum EngineCapabilities {
    // Engine identifiers, as persisted in `AppState.transcriptionEngine`.
    public static let whisperCpp = "whisper"
    public static let whisperKit = "whisperKit"
    public static let parakeet = "parakeet"
    public static let appleSpeech = "appleSpeech"

    /// Engines that bias recognition toward user-supplied vocabulary terms.
    ///
    /// Only whisper.cpp does. It accepts a free-text `initial_prompt`
    /// (`--prompt` on the CLI, a `prompt` form field on the server), which is how
    /// the vocabulary terms reach the decoder.
    ///
    /// The others do not, for three different reasons — worth keeping straight,
    /// because they have different fixes. **None of these is a dead end; all
    /// three are unwired seams, not missing capabilities:**
    ///   - **whisperKit**: biases via `DecodingOptions.promptTokens: [Int]?`, i.e.
    ///     token IDs, not a string. Wiring it needs the WhisperKit tokenizer;
    ///     deferred as a known pilot limitation (`WhisperKitBridge`).
    ///   - **parakeet**: has no prompt concept — but that's the wrong frame.
    ///     FluidAudio ships a full CTC context-biasing subsystem (a port of
    ///     NVIDIA's CTC-WS word spotter, arXiv:2406.07096) under
    ///     `ASR/Parakeet/SlidingWindow/CustomVocabulary/`, public in our pinned
    ///     0.15.5. We don't call it: it hangs off `SlidingWindowAsrManager`, and
    ///     `ParakeetBridge` uses `AsrManager`/`StreamingAsrManager`. Biasing is
    ///     post-processing over CTC log-probs, so no retrain/export change — but
    ///     TDT 0.6B v3 has no CTC head, so it needs a second ~97.5MB CTC-110M
    ///     encoder alongside. Streaming support is weak (no cross-chunk
    ///     detection); batch is where the win is. See MAK-69.
    ///     NB: FluidAudio's own `CustomVocabulary.md` documents a
    ///     `transcribe(_:customVocabulary:)` call that **does not exist** — don't
    ///     follow the doc, read the source.
    ///   - **appleSpeech**: Apple offers `SFSpeechAudioBufferRecognitionRequest`
    ///     `.contextualStrings`, which is a real seam we simply haven't wired.
    ///
    /// Note this covers **bias terms only**. Vocabulary *substitutions* are a
    /// local regex pass applied after transcription (`VocabularySubstitutor`), so
    /// they work on every engine and must stay offered everywhere.
    public static let vocabularyBiasingEngines: Set<String> = [whisperCpp]

    /// Whether `engine` biases recognition toward custom vocabulary terms.
    /// The single source of truth for the vocabulary UI's bias-terms gate and for
    /// any pipeline decision about whether building a prompt is worth the work.
    public static func supportsVocabularyBiasing(transcriptionEngine: String) -> Bool {
        vocabularyBiasingEngines.contains(transcriptionEngine)
    }

    /// Human-readable engine name, for UI that has to explain a capability gap
    /// ("… needs WhisperKit") rather than silently hiding a control.
    public static func displayName(transcriptionEngine: String) -> String {
        switch transcriptionEngine {
        case whisperCpp:   return "whisper.cpp"
        case whisperKit:   return "WhisperKit"
        case parakeet:     return "Parakeet"
        case appleSpeech:  return "Apple Speech"
        default:           return transcriptionEngine
        }
    }
}

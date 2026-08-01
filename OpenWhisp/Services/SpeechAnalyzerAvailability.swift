import Foundation

/// Runtime gate for the Apple SpeechAnalyzer engine (macOS 26, MAK-59).
///
/// SpeechAnalyzer / SpeechTranscriber ship in the Speech framework only on
/// macOS 26+. On macOS 15 the option must be hidden entirely — not offered
/// and then failing — so this is the single place that answers "can this Mac run
/// SpeechAnalyzer at all?".
///
/// Pure (no Speech import) so the UI, the pipeline, and `swift test` all consult
/// the same answer; the concrete engines add their own `if #available` guards
/// around the framework calls, but they route through this for the OS gate. The
/// engine identifier is duplicated from `EngineCapabilities.speechAnalyzer` and
/// `LanguageResolver.speechAnalyzerEngine`; `EngineCapabilitiesTests` cross-checks
/// that the three never drift.
public enum SpeechAnalyzerAvailability {
    /// The `transcriptionEngine` identifier for SpeechAnalyzer.
    public static let engineID = "speechAnalyzer"

    /// Whether this OS exposes the SpeechAnalyzer API. Runtime-gated on
    /// macOS 26; always false on 14/15 (and non-macOS). The settings picker
    /// hides the row when this is false, and `startDictation` never selects it.
    public static var isSupportedOS: Bool {
        // Compile gate first: building against a pre-macOS-26 SDK (Xcode < 26,
        // i.e. Swift < 6.2) leaves the SpeechAnalyzer symbols out of the binary
        // entirely, so the engine must report unavailable even on a macOS 26 host.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return true
        }
        #endif
        return false
    }

    /// Whether `engine` is the SpeechAnalyzer id AND this OS supports it. Callers
    /// deciding whether to route/select SpeechAnalyzer ask this so a stale stored
    /// `"speechAnalyzer"` setting on a downgraded OS can never activate a
    /// nonexistent engine.
    public static func isSelectable(engine: String) -> Bool {
        engine == engineID && isSupportedOS
    }
}

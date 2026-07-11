import Foundation

/// Canonical factory defaults for the persisted settings that `AppState.init()`
/// reads and `AppState.resetAllSettings()` restores.
///
/// These are the values that used to drift: `resetAllSettings` promises "every
/// preference goes back to its default" but had silently omitted several, so a
/// reset left them on whatever the user had. Pinning them here — and asserting in
/// `SettingsResetDefaultsTests` that they match the exact literals `init()` uses —
/// makes any future divergence a failing test instead of a shipped bug.
///
/// Only the previously-missed, literal-valued settings live here. A few resets
/// use richer canonical values that already have their own home:
///   - `screenContext`  → `ScreenContextSettings.default`
///   - `ruleSet`        → `RuleSet.empty`
///   - `parakeetVariant`→ `ParakeetCatalog.defaultVariantID`
/// `resetAllSettings` uses those directly.
enum SettingsResetDefaults {
    // Advanced formatting toggles (TranscriptCleaner inputs).
    static let normalizeNumbers = false
    static let normalizeCurrency = false
    static let spokenListsEnabled = false
    static let basicMarkdownEnabled = false

    // MAK-53 summarization model override — default "same as cleanup".
    static let summaryLLMProvider = SummaryModelResolver.sameAsCleanupID
    static let summaryLLMModel = ""
    static let summaryLLMEndpoint = ""

    // MAK-40 raw-audio retention — opt-in off; newest-50, no age cap.
    static let retainRawAudioEnabled = false
    static let audioRetentionDays = 0
    static let audioRetentionMaxClips = 50

    // Agent Bridge (M8) toggles.
    static let agentBridgeEnabled = false
    static let agentBridgeAllowUnsignedClients = false
    static let agentBridgeAllowCloudAI = false
    static let agentBridgeSilenceAutoStop = true
    static let agentBridgeEouAutoStop = false
    static let agentBridgeChimeEnabled = true
    static let agentBridgeSpeakQuestionEnabled = true
}

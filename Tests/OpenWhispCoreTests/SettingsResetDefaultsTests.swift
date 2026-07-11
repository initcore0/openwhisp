import XCTest
@testable import OpenWhispCore

/// Drift guard for the settings that `AppState.resetAllSettings()` restores. The
/// bug: reset promised "every preference goes back to its default" but silently
/// omitted several, so a reset left them on whatever the user had. These pin the
/// canonical defaults — if `AppState.init()`'s literal changes, update both it and
/// `SettingsResetDefaults` (a mismatch is the drift we're guarding against).
final class SettingsResetDefaultsTests: XCTestCase {

    func testFormattingToggleDefaultsAreOff() {
        // Match AppState.init(): all four default to false.
        XCTAssertFalse(SettingsResetDefaults.normalizeNumbers)
        XCTAssertFalse(SettingsResetDefaults.normalizeCurrency)
        XCTAssertFalse(SettingsResetDefaults.spokenListsEnabled)
        XCTAssertFalse(SettingsResetDefaults.basicMarkdownEnabled)
    }

    func testSummaryOverrideDefaultsToSameAsCleanup() {
        XCTAssertEqual(SettingsResetDefaults.summaryLLMProvider, SummaryModelResolver.sameAsCleanupID)
        XCTAssertEqual(SettingsResetDefaults.summaryLLMModel, "")
        XCTAssertEqual(SettingsResetDefaults.summaryLLMEndpoint, "")
    }

    func testRawAudioRetentionDefaults() {
        XCTAssertFalse(SettingsResetDefaults.retainRawAudioEnabled)
        XCTAssertEqual(SettingsResetDefaults.audioRetentionDays, 0)
        XCTAssertEqual(SettingsResetDefaults.audioRetentionMaxClips, 50)
    }

    func testAgentBridgeToggleDefaults() {
        XCTAssertFalse(SettingsResetDefaults.agentBridgeEnabled)
        XCTAssertFalse(SettingsResetDefaults.agentBridgeAllowUnsignedClients)
        XCTAssertFalse(SettingsResetDefaults.agentBridgeAllowCloudAI)
        // These two default ON (the expected agent-dictate UX).
        XCTAssertTrue(SettingsResetDefaults.agentBridgeSilenceAutoStop)
        XCTAssertFalse(SettingsResetDefaults.agentBridgeEouAutoStop)
        XCTAssertTrue(SettingsResetDefaults.agentBridgeChimeEnabled)
        XCTAssertTrue(SettingsResetDefaults.agentBridgeSpeakQuestionEnabled)
    }
}

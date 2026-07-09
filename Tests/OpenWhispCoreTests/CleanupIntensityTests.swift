import XCTest
@testable import OpenWhispCore

/// MAK-35: the AI-cleanup intensity dial and the raw-transcript revert model.
/// These lock the pure core — tier→prompt mapping, Codable round-trip, the
/// old-settings migration, the additive+backward-compatible history field, and
/// the revert-decision helper — so the deferred UI can wire to a proven core.
final class CleanupIntensityTests: XCTestCase {

    // MARK: - Tier → prompt mapping

    func testNoneMapsToNilPrompt() {
        XCTAssertNil(CleanupIntensity.systemPrompt(for: .none))
        XCTAssertNil(CleanupIntensity.none.systemPrompt)
        XCTAssertFalse(CleanupIntensity.none.runsLLM)
    }

    func testNonNoneTiersHaveNonEmptyPromptsAndRunLLM() {
        for tier in [CleanupIntensity.low, .medium, .high] {
            let prompt = CleanupIntensity.systemPrompt(for: tier)
            XCTAssertNotNil(prompt, "\(tier) should have a prompt")
            XCTAssertFalse(prompt!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(tier.runsLLM)
        }
    }

    func testAllTiersGuardAgainstAnsweringOrObeyingTheText() {
        // Robustness for tiny models: every non-none prompt must forbid answering
        // questions / following instructions found inside the text.
        for tier in [CleanupIntensity.low, .medium, .high] {
            let prompt = CleanupIntensity.systemPrompt(for: tier)!.lowercased()
            XCTAssertTrue(prompt.contains("do not answer") || prompt.contains("not answer"),
                          "\(tier) prompt should forbid answering questions in the text")
            XCTAssertTrue(prompt.contains("instruction"),
                          "\(tier) prompt should mention not following instructions in the text")
            XCTAssertTrue(prompt.contains("output only"),
                          "\(tier) prompt should demand output-only (no preamble)")
        }
    }

    func testLowTierIsMechanicsOnlyAndDoesNotRemoveFillers() {
        let low = CleanupIntensity.systemPrompt(for: .low)!.lowercased()
        XCTAssertTrue(low.contains("capitalization"))
        XCTAssertTrue(low.contains("punctuation"))
        // Low explicitly must NOT strip fillers or rephrase — it preserves wording.
        XCTAssertTrue(low.contains("do not change the wording") || low.contains("keep every word"))
    }

    func testMediumTierRemovesFillers() {
        let medium = CleanupIntensity.systemPrompt(for: .medium)!.lowercased()
        XCTAssertTrue(medium.contains("filler"))
        XCTAssertTrue(medium.contains("rephrase"))
    }

    func testHighTierMentionsVerbalSelfCorrection() {
        let high = CleanupIntensity.systemPrompt(for: .high)!.lowercased()
        // The headline feature of the high tier.
        XCTAssertTrue(high.contains("self-correction"))
        XCTAssertTrue(high.contains("no wait"), "high prompt should carry the '3, no wait, 4' example")
        XCTAssertTrue(high.contains("filler"), "high is additive over medium")
    }

    // MARK: - Codable round-trip

    func testEnumRoundTripsCodable() throws {
        for tier in CleanupIntensity.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(CleanupIntensity.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    func testStableRawValues() {
        // Persisted values must stay stable across versions.
        XCTAssertEqual(CleanupIntensity.none.rawValue, "none")
        XCTAssertEqual(CleanupIntensity.low.rawValue, "low")
        XCTAssertEqual(CleanupIntensity.medium.rawValue, "medium")
        XCTAssertEqual(CleanupIntensity.high.rawValue, "high")
        XCTAssertEqual(CleanupIntensity(rawValue: "high"), .high)
    }

    func testDefaultAndCaseCountAndLabels() {
        XCTAssertEqual(CleanupIntensity.allCases.count, 4)
        XCTAssertEqual(CleanupIntensity.default, .low)
        XCTAssertEqual(CleanupIntensity.none.displayLabel, "None")
        XCTAssertEqual(CleanupIntensity.high.displayLabel, "High")
    }

    // MARK: - Old single-toggle → intensity migration

    func testMigrationDisabledMapsToNone() {
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: false, enhancementMode: "rephrase"), .none)
        // Disabled wins regardless of the mode string.
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: false, enhancementMode: "improve"), .none)
    }

    func testMigrationEnabledRephraseMapsToMedium() {
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: true, enhancementMode: "rephrase"), .medium)
    }

    func testMigrationEnabledOtherModeMapsToMedium() {
        // Improve-translation / any other enabled mode also did a natural-language
        // polish, so it maps to the closest-behavior tier (.medium).
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: true, enhancementMode: "improve"), .medium)
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: true, enhancementMode: "anything"), .medium)
    }

    func testMigrationIsCaseAndWhitespaceInsensitiveForMode() {
        XCTAssertEqual(CleanupIntensity.migrated(enhancementEnabled: true, enhancementMode: "  Rephrase "), .medium)
    }

    // MARK: - History: raw-transcript storage, additive + backward-compatible

    func testEntryStoresRawTextAndRoundTrips() throws {
        let entry = TranscriptionEntry(
            text: "Hello, team.",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            appBundleID: "com.example.app",
            appName: "Example",
            rawText: "um hello team"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.rawText, "um hello team")
    }

    func testOldEntryJSONWithoutRawTextStillDecodes() throws {
        // A history.json entry written before rawText existed. It MUST still
        // decode (rawText → nil), or the whole store would fail to load.
        let oldJSON = """
        {
            "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
            "text": "hello team",
            "date": 700000000,
            "appBundleID": "com.example.app",
            "appName": "Example"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TranscriptionEntry.self, from: oldJSON)
        XCTAssertEqual(decoded.text, "hello team")
        XCTAssertNil(decoded.rawText)
        // And an array of such old entries loads too.
        let arr = "[\(String(data: oldJSON, encoding: .utf8)!)]".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: arr).count, 1)
    }

    func testEntryDefaultsRawTextToNilWhenOmitted() {
        let entry = TranscriptionEntry(
            text: "hi", date: Date(), appBundleID: nil, appName: nil
        )
        XCTAssertNil(entry.rawText)
    }

    // MARK: - Revert helper

    func testRevertTargetReturnsRawWhenItDiffers() {
        let entry = TranscriptionEntry(
            text: "Hello, team.", date: Date(), appBundleID: nil, appName: nil,
            rawText: "um hello team"
        )
        XCTAssertEqual(entry.revertTarget, "um hello team")
    }

    func testRevertTargetIsNilWhenNoRawStored() {
        let entry = TranscriptionEntry(
            text: "Hello, team.", date: Date(), appBundleID: nil, appName: nil
        )
        XCTAssertNil(entry.revertTarget)
    }

    func testRevertTargetIsNilWhenRawEqualsText() {
        // No cleanup ran (raw == final): "revert" would be a no-op, so hide it.
        let entry = TranscriptionEntry(
            text: "hello team", date: Date(), appBundleID: nil, appName: nil,
            rawText: "hello team"
        )
        XCTAssertNil(entry.revertTarget)
    }
}

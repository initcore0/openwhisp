import XCTest
@testable import OpenWhispCore

/// Tests for the `SettingsStore` seam that MAK-32 extracted AppState's ~91
/// `didSet`/UserDefaults persistence blocks behind. AppState itself is AppKit-only
/// and isn't linked here, so these exercise the seam the extraction liberated:
/// the store protocol round-trips the same keys/values AppState now routes
/// through, migration runs against it, and a golden key list guards the on-disk
/// contract (iOS companion, MAK-51) against a silent rename.
final class SettingsStoreTests: XCTestCase {

    /// In-memory `SettingsStore` — the same seam SettingsMigrationTests uses,
    /// standing in for `UserDefaults.standard`. Only the two primitives are
    /// implemented; the typed accessors (`string`/`bool`/`integer`/…) come from
    /// the protocol's default implementations, so this proves those defaults too.
    private final class MemoryStore: SettingsStore {
        var values: [String: Any] = [:]
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
        }
    }

    // MARK: - Round-trip

    /// The write path AppState's `didSet` blocks use (`store.set(value, forKey:)`)
    /// must be read back byte-for-byte through the typed accessors AppState's init
    /// uses — same key, same value, no coercion surprises.
    func testTypedAccessorsRoundTripThroughStore() {
        let store = MemoryStore()

        store.set("large-v3-turbo", forKey: "modelName")
        store.set(true, forKey: "restoreClipboard")
        store.set(false, forKey: "smartFormattingEnabled")
        store.set(7, forKey: "audioRetentionDays")
        store.set(["a", "b"], forKey: "dismissedHintIDs")
        let blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        store.set(blob, forKey: "outputTargetSettings")

        XCTAssertEqual(store.string(forKey: "modelName"), "large-v3-turbo")
        XCTAssertTrue(store.bool(forKey: "restoreClipboard"))
        XCTAssertFalse(store.bool(forKey: "smartFormattingEnabled"))
        XCTAssertEqual(store.integer(forKey: "audioRetentionDays"), 7)
        XCTAssertEqual(store.stringArray(forKey: "dismissedHintIDs"), ["a", "b"])
        XCTAssertEqual(store.data(forKey: "outputTargetSettings"), blob)
    }

    /// Absent keys read as the documented zero values (mirrors UserDefaults),
    /// which is what AppState's `?? default` init fallbacks rely on.
    func testTypedAccessorsDefaultsForMissingKeys() {
        let store = MemoryStore()
        XCTAssertNil(store.string(forKey: "modelName"))
        XCTAssertFalse(store.bool(forKey: "restoreClipboard"))
        XCTAssertEqual(store.integer(forKey: "audioRetentionDays"), 0)
        XCTAssertNil(store.data(forKey: "outputTargetSettings"))
        XCTAssertNil(store.stringArray(forKey: "dismissedHintIDs"))
    }

    /// A UserDefaults-persisted Bool can come back boxed as an NSNumber; the
    /// default `bool`/`integer` accessors must unwrap that so migrated/round-
    /// tripped values don't silently read as `false`/`0`.
    func testTypedAccessorsUnwrapNSNumber() {
        let store = MemoryStore()
        store.set(NSNumber(value: true), forKey: "historyEnabled")
        store.set(NSNumber(value: 42), forKey: "audioRetentionMaxClips")
        XCTAssertTrue(store.bool(forKey: "historyEnabled"))
        XCTAssertEqual(store.integer(forKey: "audioRetentionMaxClips"), 42)
    }

    // MARK: - Migration interplay

    /// The store AppState reads its settings from is the SAME store the migration
    /// wrote to (AppState now passes `settingsStore` to both). This proves the
    /// wiring: migrate an existing pre-v2 install, then read the migrated keys
    /// back through the accessors AppState's init uses — they must reflect the
    /// migration, not the raw pre-migration state.
    func testMigrationThenTypedReadThroughSameStore() {
        let store = MemoryStore()
        store.set(true, forKey: "didCompleteOnboarding")   // existing-install marker
        store.set("en", forKey: "language")                // legacy translate overload

        SettingsMigration.migrate(store)

        // AppState init reads these exact keys via these exact accessors.
        XCTAssertEqual(store.string(forKey: "language"), "auto")
        XCTAssertTrue(store.bool(forKey: "translateToEnglish"))
        XCTAssertEqual(store.string(forKey: "modelName"), "tiny")           // v2 preserved default
        XCTAssertFalse(store.bool(forKey: "restoreClipboard"))              // v2 preserved default
        XCTAssertEqual(store.integer(forKey: "settingsVersion"),
                       SettingsMigration.currentVersion)
    }

    /// A fresh install must not have old defaults written — AppState's read
    /// fallbacks supply the new defaults. Confirms migrate-then-read leaves the
    /// changed-default keys absent so the fallback wins.
    func testFreshInstallLeavesChangedDefaultsToAppStateFallbacks() {
        let store = MemoryStore()
        SettingsMigration.migrate(store)
        XCTAssertNil(store.string(forKey: "modelName"))
        XCTAssertNil(store.string(forKey: "llmProvider"))
        XCTAssertEqual(store.integer(forKey: "settingsVersion"),
                       SettingsMigration.currentVersion)
    }

    // MARK: - Golden key-set drift guard

    /// Every UserDefaults key AppState persists is the on-disk settings contract
    /// shared with the iOS companion (MAK-51). Renaming one silently would orphan
    /// a user's saved setting (and desync the two apps). This asserts the exact
    /// set of `forKey:` string literals in AppState.swift matches a checked-in
    /// golden list — a rename or a new/removed key fails here until the golden
    /// list is updated deliberately (and, for a rename, a migration added).
    func testAppStateUserDefaultsKeySetHasNotDrifted() throws {
        let source = try String(contentsOf: Self.appStateSourceURL, encoding: .utf8)

        // Extract every `forKey: "<key>"` literal.
        let pattern = #"forKey:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        var found = Set<String>()
        for match in regex.matches(in: source, range: range) {
            if let r = Range(match.range(at: 1), in: source) {
                found.insert(String(source[r]))
            }
        }

        let missing = Self.goldenKeys.subtracting(found)
        let added = found.subtracting(Self.goldenKeys)

        XCTAssertTrue(
            missing.isEmpty && added.isEmpty,
            """
            AppState UserDefaults key set drifted from the golden list.
              removed/renamed-away: \(missing.sorted())
              new/renamed-to:       \(added.sorted())

            If you renamed a key, you must add a SettingsMigration step so existing
            installs (and the iOS companion) keep their saved value — then update
            the golden list in this test. If you added/removed a key intentionally,
            update the golden list. Do NOT just delete this assertion.
            """
        )
    }

    /// Path to the checked-in AppState.swift, resolved relative to this test file
    /// (Tests/OpenWhispCoreTests/ -> ../../OpenWhisp/Models/AppState.swift).
    private static let appStateSourceURL: URL = {
        URL(fileURLWithPath: #filePath)               // .../Tests/OpenWhispCoreTests/SettingsStoreTests.swift
            .deletingLastPathComponent()              // .../Tests/OpenWhispCoreTests
            .deletingLastPathComponent()              // .../Tests
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("OpenWhisp/Models/AppState.swift")
    }()

    /// The complete set of UserDefaults keys AppState.swift reads or writes.
    /// This is the versioned on-disk settings contract — keep it in sync ONLY via
    /// a deliberate change + (for renames) a migration.
    private static let goldenKeys: Set<String> = [
        "addTrailingSpace",
        "agentBridgeAllowCloudAI",
        "agentBridgeAllowUnsignedClients",
        "agentBridgeChimeEnabled",
        "agentBridgeEnabled",
        "agentBridgeEouAutoStop",
        "agentBridgeSilenceAutoStop",
        "agentBridgeSpeakQuestionEnabled",
        "agentCLICustomArgsText",
        "agentCLICustomCommand",
        "agentCLIPreset",
        "agentCLITimeout",
        "audioRetentionDays",
        "audioRetentionMaxClips",
        "autoGainEnabled",
        "basicMarkdownEnabled",
        "bundledLLMModel",
        "cleanupIntensity",
        "correctionLearningEnabled",
        "customTriggerKeyCode",
        "customTriggerModifiers",
        "customVocabularyEnabled",
        "debugOverlayEnabled",
        "didCompleteOnboarding",
        "dismissedHintIDs",
        "fileTaggingEnabled",
        "fillerRemovalEnabled",
        "handsFreeSilenceAutoStop",
        "hintSessionCount",
        "historyEnabled",
        "hotkeyMode",
        "insertionMode",
        "instructionChainEnabled",
        "language",
        "lastNonNoneCleanupIntensity",
        "liveChunkDuration",
        "llmProvider",
        "localLLMBaseURL",
        "localLLMModel",
        "microphoneID",
        "modelName",
        "modelPath",
        "mouseTrigger",
        "normalizeCurrency",
        "normalizeNumbers",
        "openAIAPIKey",
        "openAIEnhancementEnabled",
        "openAIEnhancementMode",
        "openAIModel",
        "outputMode",
        "outputTargetSettings",
        "parakeetVariant",
        "pauseBasedLiveChunksEnabled",
        "perAppModesEnabled",
        "quietDictationEnabled",
        "refineKey",
        "restoreClipboard",
        "retainRawAudioEnabled",
        "screenContextSettings",
        "scriptPostProcessorEnabled",
        "scriptPostProcessorPath",
        "showOverlay",
        "smartFormattingEnabled",
        "spokenListsEnabled",
        "spokenPunctuationEnabled",
        // Stream overlay (live subtitles for OBS/Twitch) — added with the feature.
        "streamOverlayConfig",
        "streamOverlayEnabled",
        "streamOverlayPort",
        "summaryLLMEndpoint",
        "summaryLLMModel",
        "summaryLLMProvider",
        "transcriptionEngine",
        "translateToEnglish",
        "translationTargetLanguage",
        "triggerMode",
        "voiceEditingEnabled",
        "voiceIndicatorStyle",
        "whisperBackend",
        "whisperBinaryPath",
        "whisperKitModel",
    ]
}

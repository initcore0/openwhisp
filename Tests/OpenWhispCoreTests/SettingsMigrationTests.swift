import XCTest
@testable import OpenWhispCore

/// In-memory SettingsStore so migrations run against a plain dictionary.
private final class MemoryStore: SettingsStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

final class SettingsMigrationTests: XCTestCase {

    func testFreshInstallGetsVersionStampOnly() {
        let store = MemoryStore()
        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values[SettingsMigration.versionKey] as? Int,
                       SettingsMigration.currentVersion)
        // New defaults apply via AppState's read fallbacks — the migration must
        // not write old defaults into a fresh install.
        XCTAssertNil(store.values["modelName"])
        XCTAssertNil(store.values["llmProvider"])
        XCTAssertNil(store.values["restoreClipboard"])
        XCTAssertNil(store.values["translateToEnglish"])
    }

    func testExistingInstallKeepsOldDefaultsForUntouchedKeys() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true   // install marker

        SettingsMigration.migrate(store)

        // The defaults changed in v2, so an existing install that never
        // customized these must get the OLD values written explicitly.
        XCTAssertEqual(store.values["modelName"] as? String, "tiny")
        XCTAssertEqual(store.values["restoreClipboard"] as? Bool, false)
        // llmProvider: v2 preserves the old "openai" default, but v3 then snaps
        // a DORMANT provider (AI cleanup off) to "bundled" — so a 0→3 jump
        // lands on bundled.
        XCTAssertEqual(store.values["llmProvider"] as? String, "bundled")
        XCTAssertEqual(store.values[SettingsMigration.versionKey] as? Int,
                       SettingsMigration.currentVersion)
    }

    func testExistingInstallKeepsCustomizedValues() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values["modelName"] = "large-v3-turbo"
        store.values["llmProvider"] = "local"
        store.values["openAIEnhancementEnabled"] = true   // provider actively in use
        store.values["restoreClipboard"] = true

        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["modelName"] as? String, "large-v3-turbo")
        XCTAssertEqual(store.values["llmProvider"] as? String, "local")
        XCTAssertEqual(store.values["restoreClipboard"] as? Bool, true)
    }

    func testLegacyEnglishSplitsIntoAutoPlusTranslate() {
        let store = MemoryStore()
        store.values["language"] = "en"   // also serves as the install marker

        SettingsMigration.migrate(store)

        // Old semantics: "en" meant translate-to-English with auto-detected
        // source. The split must preserve that behavior exactly.
        XCTAssertEqual(store.values["language"] as? String, "auto")
        XCTAssertEqual(store.values["translateToEnglish"] as? Bool, true)
    }

    func testNonEnglishLanguageIsLeftAlone() {
        let store = MemoryStore()
        store.values["language"] = "ru"

        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["language"] as? String, "ru")
        XCTAssertNil(store.values["translateToEnglish"])
    }

    // MARK: - v3

    func testStoredRightControlRefineKeyBecomesLeftControl() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values["refineKey"] = "rightControl"   // impossible on MacBook keyboards

        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["refineKey"] as? String, "leftControl")
    }

    func testOtherRefineKeysAreLeftAlone() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values["refineKey"] = "rightOption"

        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["refineKey"] as? String, "rightOption")
    }

    func testDormantProviderSnapsToBundled() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values["llmProvider"] = "local"   // configured but AI cleanup is off

        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["llmProvider"] as? String, "bundled")
    }

    func testActiveProviderIsNeverTouched() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values["openAIEnhancementEnabled"] = true
        store.values["llmProvider"] = "openai"

        SettingsMigration.migrate(store)

        // AI cleanup is actually in use with OpenAI — leave it alone.
        XCTAssertEqual(store.values["llmProvider"] as? String, "openai")
    }

    func testVersion2InstallGetsOnlyV3Steps() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true
        store.values[SettingsMigration.versionKey] = 2
        store.values["refineKey"] = "rightControl"
        store.values["language"] = "en"   // legitimately "spoken English" post-v2

        SettingsMigration.migrate(store)

        // v3 step applies…
        XCTAssertEqual(store.values["refineKey"] as? String, "leftControl")
        // …but the v2 language split must NOT re-run.
        XCTAssertEqual(store.values["language"] as? String, "en")
        XCTAssertNil(store.values["translateToEnglish"])
        XCTAssertEqual(store.values[SettingsMigration.versionKey] as? Int,
                       SettingsMigration.currentVersion)
    }

    func testMigrationRunsOnlyOnce() {
        let store = MemoryStore()
        store.values["didCompleteOnboarding"] = true

        SettingsMigration.migrate(store)
        // Simulate the user choosing the new defaults afterwards…
        store.values["llmProvider"] = "bundled"
        store.values["language"] = "en"   // now legitimately "spoken English"
        // …a second migrate (next launch) must not undo any of it.
        SettingsMigration.migrate(store)

        XCTAssertEqual(store.values["llmProvider"] as? String, "bundled")
        XCTAssertEqual(store.values["language"] as? String, "en")
        XCTAssertNil(store.values["translateToEnglish"])
    }
}

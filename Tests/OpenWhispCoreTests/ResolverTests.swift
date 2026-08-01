import XCTest
@testable import OpenWhispCore

/// Tests for the pure session-setting resolvers extracted from AppState
/// (LanguageResolver, ProfileResolver) — the translate/auto/appleSpeech matrix and
/// the per-app-profile "en" → translate remap + inherit-vs-override rules.
final class LanguageResolverTests: XCTestCase {

    func testExplicitLanguageNoTranslatePassesThrough() {
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "fr", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "fr")
    }

    /// The engine NEVER gets the translate sentinel any more: translation
    /// unified on the Apple Translation text path, so whisperKit — the one
    /// engine that used to receive it — is handed the plain spoken language and
    /// its native translate task is dormant.
    func testTranslateNeverReturnsSentinelForWhisper() {
        let setting = LanguageResolver.engineLanguageSetting(
            language: "fr", translateToEnglish: true, transcriptionEngine: "whisperKit")
        XCTAssertEqual(setting, "fr")
        XCTAssertNotEqual(setting, WhisperTask.translateToEnglishSetting)
    }

    func testAppleSpeechNeverTranslates() {
        // Apple Speech has no translate concept — even with translateToEnglish on,
        // it gets the plain language.
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "fr", translateToEnglish: true, transcriptionEngine: "appleSpeech"),
            "fr")
    }

    func testAutoLanguagePassesThrough() {
        XCTAssertEqual(
            LanguageResolver.engineLanguageSetting(
                language: "auto", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "auto")
    }

    func testOutputLanguageIsEnglishWhenTranslating() {
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: true, transcriptionEngine: "whisperKit"),
            "en")
    }

    func testOutputLanguageIsSpokenWhenNotTranslating() {
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: false, transcriptionEngine: "whisperKit"),
            "de")
    }

    func testOutputLanguageAppleSpeechIgnoresTranslate() {
        XCTAssertEqual(
            LanguageResolver.outputLanguageForCleaning(
                language: "de", translateToEnglish: true, transcriptionEngine: "appleSpeech"),
            "de")
    }

    /// The refine layer (cleanup prompts, RefineOutputGuard's expected script)
    /// must key on the EFFECTIVE translate intent. On every no-translate engine a
    /// stale stored `true` must read as false — otherwise the language guard
    /// expects Latin output and accepts a cleanup pass that translated the
    /// dictation away (the exact bug the guard exists to prevent).
    func testEffectiveTranslateIsFalseOnNoTranslateEngines() {
        for engine in LanguageResolver.noTranslateEngines {
            XCTAssertFalse(
                LanguageResolver.effectiveTranslateToEnglish(
                    translateToEnglish: true, transcriptionEngine: engine),
                "\(engine) cannot translate — the stored flag must not leak into the refine layer")
        }
    }

    func testEffectiveTranslatePassesThroughOnTranslatingEngines() {
        for engine in ["whisper", "whisperKit"] {
            XCTAssertTrue(
                LanguageResolver.effectiveTranslateToEnglish(
                    translateToEnglish: true, transcriptionEngine: engine))
            XCTAssertFalse(
                LanguageResolver.effectiveTranslateToEnglish(
                    translateToEnglish: false, transcriptionEngine: engine))
        }
    }
}

final class ProfileResolverTests: XCTestCase {

    private let baseGlobals = ProfileResolver.Globals(
        language: "auto", translateToEnglish: false, outputMode: "preview",
        aiCleanupEnabled: false, insertionMode: "auto")

    private func profile(
        language: String? = nil, outputMode: String? = nil, aiCleanup: Bool? = nil,
        insertionMode: String? = nil
    ) -> AppProfile {
        AppProfile(appBundleID: "com.test.app", displayName: "Test",
                   language: language, outputMode: outputMode, aiCleanupEnabled: aiCleanup,
                   insertionMode: insertionMode)
    }

    func testNilFieldsInheritGlobals() {
        let r = ProfileResolver.resolve(profile: profile(), over: baseGlobals)
        XCTAssertEqual(r, ProfileResolver.Resolved(
            language: "auto", translateToEnglish: false, outputMode: "preview",
            aiCleanupEnabled: false, insertionMode: "auto"))
    }

    func testInsertionModeInheritsGlobalWhenNil() {
        var g = baseGlobals; g.insertionMode = "paste"
        let r = ProfileResolver.resolve(profile: profile(), over: g)
        XCTAssertEqual(r.insertionMode, "paste")
    }

    func testInsertionModeOverride() {
        // A per-app profile forcing AppleScript keystroke for an Electron/VNC app.
        let r = ProfileResolver.resolve(
            profile: profile(insertionMode: "appleScript"), over: baseGlobals)
        XCTAssertEqual(r.insertionMode, "appleScript")
    }

    func testEnLanguageRemapsToAutoPlusTranslate() {
        // The historical semantics: profile language "en" means translate-to-English
        // with the source auto-detected.
        let r = ProfileResolver.resolve(profile: profile(language: "en"), over: baseGlobals)
        XCTAssertEqual(r.language, "auto")
        XCTAssertTrue(r.translateToEnglish)
    }

    func testExplicitLanguageDisablesTranslate() {
        // Start from a global where translate is ON to prove the profile turns it off.
        var g = baseGlobals; g.translateToEnglish = true
        let r = ProfileResolver.resolve(profile: profile(language: "fr"), over: g)
        XCTAssertEqual(r.language, "fr")
        XCTAssertFalse(r.translateToEnglish)
    }

    func testNilLanguageLeavesTranslateAtGlobal() {
        // The remap only fires when the profile pins a language; a nil language must
        // not touch translateToEnglish.
        var g = baseGlobals; g.translateToEnglish = true
        let r = ProfileResolver.resolve(profile: profile(outputMode: "finalOnly"), over: g)
        XCTAssertEqual(r.language, "auto")          // inherited
        XCTAssertTrue(r.translateToEnglish)         // inherited, not reset
        XCTAssertEqual(r.outputMode, "finalOnly")   // overridden
    }

    func testOutputModeAndAICleanupOverride() {
        let r = ProfileResolver.resolve(
            profile: profile(outputMode: "liveChunks", aiCleanup: true), over: baseGlobals)
        XCTAssertEqual(r.outputMode, "liveChunks")
        XCTAssertTrue(r.aiCleanupEnabled)
    }

    func testProfileMatcherPicksByBundleID() {
        // The matcher AppState uses to find the active profile — part of the same seam.
        let profiles = [
            AppProfile(appBundleID: "com.a", displayName: "A", language: "fr",
                       outputMode: nil, aiCleanupEnabled: nil),
            AppProfile(appBundleID: "com.b", displayName: "B", language: "de",
                       outputMode: nil, aiCleanupEnabled: nil),
        ]
        XCTAssertEqual(AppProfileStore.profile(for: "com.b", in: profiles)?.language, "de")
        XCTAssertNil(AppProfileStore.profile(for: "com.unknown", in: profiles))
        XCTAssertNil(AppProfileStore.profile(for: nil, in: profiles))
    }
}

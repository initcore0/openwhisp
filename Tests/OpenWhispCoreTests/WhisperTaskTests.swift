import XCTest
@testable import OpenWhispCore

final class WhisperTaskTests: XCTestCase {
    func testTranslateSentinelMeansTranslateWithAutoSource() {
        // whisper's --translate always targets English and needs the source
        // auto-detected, so the sentinel must become (auto, translate=true).
        XCTAssertEqual(WhisperTask.resolve(languageSetting: WhisperTask.translateToEnglishSetting),
                       .init(language: "auto", translate: true))
    }

    func testEnglishIsAPlainSourceLanguage() {
        // Since the translateToEnglish split, "en" honestly means "the speech
        // is English" — the old overload (en → translate) is migrated away.
        XCTAssertEqual(WhisperTask.resolve(languageSetting: "en"),
                       .init(language: "en", translate: false))
    }

    func testAutoTranscribesNoTranslate() {
        XCTAssertEqual(WhisperTask.resolve(languageSetting: "auto"),
                       .init(language: "auto", translate: false))
    }

    func testSpecificLanguageTranscribesNoTranslate() {
        XCTAssertEqual(WhisperTask.resolve(languageSetting: "ru"),
                       .init(language: "ru", translate: false))
        XCTAssertEqual(WhisperTask.resolve(languageSetting: "de"),
                       .init(language: "de", translate: false))
    }

    func testEmptyFallsBackToAuto() {
        XCTAssertEqual(WhisperTask.resolve(languageSetting: ""),
                       .init(language: "auto", translate: false))
    }

    func testSentinelIsNotALanguageCode() {
        // The sentinel must never collide with a legitimate picker value.
        XCTAssertFalse(["auto", "en", "ru", "es", "fr", "de", "it", "pt", "ja", "zh", "ko", "ar"]
            .contains(WhisperTask.translateToEnglishSetting))
    }
}

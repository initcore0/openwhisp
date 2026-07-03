import XCTest
@testable import OpenWhispCore

/// The pure language→task mapper for the WhisperKit pilot. (The WhisperKit API
/// bridge itself is behind `#if WHISPERKIT` and not part of the test build.)
/// Mirrors WhisperTaskTests: the shared sentinel means translate-to-English
/// with the source auto-detected; plain "en" is an explicit source language.
final class WhisperKitTaskMapperTests: XCTestCase {
    func testTranslateSentinelMeansTranslateWithAutoSource() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: WhisperTask.translateToEnglishSetting),
                       .init(language: nil, translate: true))
    }

    func testEnglishIsAPlainSourceLanguage() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: "en"),
                       .init(language: "en", translate: false))
    }

    func testAutoTranscribesNoTranslate() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: "auto"),
                       .init(language: nil, translate: false))
    }

    func testEmptyFallsBackToAutoTranscribe() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: ""),
                       .init(language: nil, translate: false))
    }

    func testSpecificLanguageTranscribesInThatLanguage() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: "ru"),
                       .init(language: "ru", translate: false))
    }
}

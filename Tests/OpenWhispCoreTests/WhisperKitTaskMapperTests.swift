import XCTest
@testable import OpenWhispCore

/// The pure language→task mapper for the WhisperKit pilot. (The WhisperKit API
/// bridge itself is behind `#if WHISPERKIT` and not part of the test build.)
/// Mirrors WhisperTaskTests: "en" must mean translate-to-English with the source
/// auto-detected, not "source is English".
final class WhisperKitTaskMapperTests: XCTestCase {
    func testEnglishMeansTranslateWithAutoSource() {
        XCTAssertEqual(WhisperKitTaskMapper.map(languageSetting: "en"),
                       .init(language: nil, translate: true))
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

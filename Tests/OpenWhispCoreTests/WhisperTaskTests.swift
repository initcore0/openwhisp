import XCTest
@testable import OpenWhispCore

final class WhisperTaskTests: XCTestCase {
    func testEnglishMeansTranslateWithAutoSource() {
        // The bug: "en" must become (auto, translate=true), NOT (en, translate=false)
        // — otherwise whisper treats the source as English and never translates.
        XCTAssertEqual(WhisperTask.resolve(languageSetting: "en"),
                       .init(language: "auto", translate: true))
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
}

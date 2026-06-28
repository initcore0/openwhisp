import XCTest
@testable import OpenWhispCore

final class VoiceIndicatorStyleTests: XCTestCase {

    func testRawValueRoundTrips() {
        for style in VoiceIndicatorStyle.allCases {
            XCTAssertEqual(VoiceIndicatorStyle(rawValue: style.rawValue), style)
        }
    }

    func testFromDefaultsToWaveform() {
        XCTAssertEqual(VoiceIndicatorStyle.from(nil), .waveform)
        XCTAssertEqual(VoiceIndicatorStyle.from("nonsense"), .waveform)
        XCTAssertEqual(VoiceIndicatorStyle.from(""), .waveform)
    }

    func testFromValidRawValue() {
        XCTAssertEqual(VoiceIndicatorStyle.from("bars"), .bars)
        XCTAssertEqual(VoiceIndicatorStyle.from("orb"), .orb)
        XCTAssertEqual(VoiceIndicatorStyle.from("waveform"), .waveform)
    }

    func testEveryStyleHasLabelAndDetail() {
        for style in VoiceIndicatorStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.detail.isEmpty)
        }
    }
}

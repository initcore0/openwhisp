import XCTest
@testable import OpenWhispCore

final class PrivacyStatusTests: XCTestCase {

    func testFullyLocalWhenEnhancementOff() {
        XCTAssertFalse(PrivacyStatus.sendsTextToCloud(enhancementEnabled: false, provider: "openai"))
        XCTAssertEqual(PrivacyStatus.statusText(enhancementEnabled: false, provider: "openai"),
                       "Fully on-device — no network used")
    }

    func testLocalProviderNeverCloud() {
        XCTAssertFalse(PrivacyStatus.sendsTextToCloud(enhancementEnabled: true, provider: "local"))
        XCTAssertEqual(PrivacyStatus.statusText(enhancementEnabled: true, provider: "local"),
                       "On-device + your local LLM — nothing goes to the cloud")
    }

    func testOpenAIEnabledSendsToCloud() {
        XCTAssertTrue(PrivacyStatus.sendsTextToCloud(enhancementEnabled: true, provider: "openai"))
        XCTAssertEqual(PrivacyStatus.statusText(enhancementEnabled: true, provider: "openai"),
                       "Sends final text to OpenAI for cleanup")
    }

    func testOpenAIProviderButEnhancementOffIsLocal() {
        // Provider set to openai but cleanup off → nothing is sent.
        XCTAssertFalse(PrivacyStatus.sendsTextToCloud(enhancementEnabled: false, provider: "openai"))
    }
}

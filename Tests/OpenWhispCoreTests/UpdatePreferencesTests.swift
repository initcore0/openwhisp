import XCTest
@testable import OpenWhispCore

/// The pure auto-update preference resolver (MAK-56). The Sparkle wiring lives in
/// the AppKit layer (can't be unit-tested here), so the one decision that matters
/// — "is the automatic-check toggle on?" — is extracted into core and tested.
final class UpdatePreferencesTests: XCTestCase {

    func testDefaultsOnWhenNeverSet() {
        // Fresh install / upgrade: no stored value ⇒ ON (matches
        // SUEnableAutomaticChecks=YES in Info.plist).
        XCTAssertTrue(UpdatePreferences.automaticChecksEnabled(storedValue: nil))
    }

    func testHonorsExplicitOff() {
        // A user who unchecked the box must stay opted out across launches.
        XCTAssertFalse(UpdatePreferences.automaticChecksEnabled(storedValue: false))
    }

    func testHonorsExplicitOn() {
        XCTAssertTrue(UpdatePreferences.automaticChecksEnabled(storedValue: true))
    }

    func testKeyIsStable() {
        // The key is a persistence contract; changing it silently resets every
        // user's preference. Pin it.
        XCTAssertEqual(UpdatePreferences.automaticChecksKey, "sparkleAutomaticChecksEnabled")
    }
}

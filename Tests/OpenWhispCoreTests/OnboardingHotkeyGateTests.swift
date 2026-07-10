import XCTest
@testable import OpenWhispCore

/// MAK-24: the onboarding hotkey/"try it" gate must never present a hotkey that
/// is guaranteed dead (Input Monitoring denied), yet must not false-alarm when
/// the live state is unknowable.
final class OnboardingHotkeyGateTests: XCTestCase {

    func testReadinessGrantedIsReady() {
        XCTAssertEqual(
            OnboardingHotkeyGate.readiness(inputMonitoring: .granted),
            .ready
        )
    }

    func testReadinessDeniedIsBlocked() {
        XCTAssertEqual(
            OnboardingHotkeyGate.readiness(inputMonitoring: .denied),
            .blocked
        )
    }

    func testReadinessUnknownIsUnconfirmed() {
        XCTAssertEqual(
            OnboardingHotkeyGate.readiness(inputMonitoring: .unknown),
            .unconfirmed
        )
    }

    // The core guard: only a CONFIRMED denial warns; unknown must stay silent so
    // systems where we can't read the state don't get a false "hotkey is dead".
    func testWarnsOnlyOnConfirmedDenial() {
        XCTAssertTrue(OnboardingHotkeyGate.shouldWarnHotkeyDead(inputMonitoring: .denied))
        XCTAssertFalse(OnboardingHotkeyGate.shouldWarnHotkeyDead(inputMonitoring: .granted))
        XCTAssertFalse(OnboardingHotkeyGate.shouldWarnHotkeyDead(inputMonitoring: .unknown))
    }
}

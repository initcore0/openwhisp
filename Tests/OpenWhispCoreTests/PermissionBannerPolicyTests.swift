import XCTest
@testable import OpenWhispCore

final class PermissionBannerPolicyTests: XCTestCase {

    func testAllGrantedShowsNoBanners() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: true),
            []
        )
    }

    func testMissingAccessibilityShowsAccessibilityBanner() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: true),
            [.accessibility]
        )
    }

    func testMissingInputMonitoringShowsInputMonitoringBanner() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: false),
            [.inputMonitoring]
        )
    }

    func testBothMissingShowsBothInStableOrder() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: false),
            [.accessibility, .inputMonitoring]
        )
    }

    /// Before the hotkey event-tap attempt reports, Input Monitoring is unknown —
    /// no banner for a state we haven't confirmed.
    func testUnknownInputMonitoringShowsNoInputMonitoringBanner() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: nil),
            [.accessibility]
        )
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: nil),
            []
        )
    }

    func testDismissHidesBannerWhilePermissionStillMissing() {
        var policy = PermissionBannerPolicy()
        _ = policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: false)
        policy.dismiss(.accessibility)
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: false),
            [.inputMonitoring]
        )
    }

    func testDismissingOneBannerDoesNotAffectTheOther() {
        var policy = PermissionBannerPolicy()
        policy.dismiss(.inputMonitoring)
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: false),
            [.accessibility]
        )
    }

    /// The banner auto-clears when the permission is granted (the become-active
    /// refresh re-evaluates with the new live state).
    func testGrantingPermissionClearsItsBanner() {
        var policy = PermissionBannerPolicy()
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: false),
            [.accessibility, .inputMonitoring]
        )
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: false),
            [.inputMonitoring]
        )
    }

    /// Grant → dismissal is re-armed → a later revocation (e.g. reinstall) shows
    /// the banner again instead of staying muted forever.
    func testGrantReArmsDismissedBannerForLaterRevocation() {
        var policy = PermissionBannerPolicy()
        _ = policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: true)
        policy.dismiss(.accessibility)
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: true),
            []
        )
        // User grants it in System Settings…
        _ = policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: true)
        // …then a reinstall revokes it again: the banner must come back.
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: true),
            [.accessibility]
        )
    }

    func testDismissalWhileGrantedDoesNotStick() {
        var policy = PermissionBannerPolicy()
        policy.dismiss(.accessibility)
        // Granted state clears the dismissal…
        _ = policy.visibleBanners(accessibilityGranted: true, inputMonitoringGranted: true)
        // …so a revocation still surfaces the banner.
        XCTAssertEqual(
            policy.visibleBanners(accessibilityGranted: false, inputMonitoringGranted: true),
            [.accessibility]
        )
    }

    func testBannerCopyIsPresentAndDistinct() {
        for permission in PermissionBannerPolicy.Permission.allCases {
            XCTAssertFalse(permission.bannerTitle.isEmpty)
            XCTAssertFalse(permission.bannerMessage.isEmpty)
            XCTAssertFalse(permission.bannerButtonTitle.isEmpty)
        }
        XCTAssertNotEqual(
            PermissionBannerPolicy.Permission.accessibility.bannerTitle,
            PermissionBannerPolicy.Permission.inputMonitoring.bannerTitle
        )
        XCTAssertNotEqual(
            PermissionBannerPolicy.Permission.accessibility.bannerMessage,
            PermissionBannerPolicy.Permission.inputMonitoring.bannerMessage
        )
    }
}

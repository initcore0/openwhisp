import XCTest
@testable import OpenWhispCore

/// Covers the re-sync decision that AppState's `launchAtLogin` didSet makes after
/// asking the system to toggle the login item. The SMAppService backend can't be
/// unit-tested without a signed bundle, but this pure reconciler is the branchy
/// part that actually decided what the toggle and error message become.
final class LaunchAtLoginReconcilerTests: XCTestCase {
    typealias Reconciler = LaunchAtLoginReconciler

    func testEnablingSucceeds() {
        let outcome = Reconciler.reconcile(
            desired: true, applied: true, actual: true, requiresApproval: false
        )
        XCTAssertEqual(outcome, .init(resolvedValue: true, needsApprovalMessage: false))
    }

    func testDisablingSucceeds() {
        let outcome = Reconciler.reconcile(
            desired: false, applied: true, actual: false, requiresApproval: false
        )
        XCTAssertEqual(outcome, .init(resolvedValue: false, needsApprovalMessage: false))
    }

    func testEnableBlockedNeedingApproval() {
        // User flipped it on, but macOS keeps it off pending approval.
        let outcome = Reconciler.reconcile(
            desired: true, applied: true, actual: false, requiresApproval: true
        )
        XCTAssertEqual(outcome.resolvedValue, false, "toggle should snap back to reality")
        XCTAssertTrue(outcome.needsApprovalMessage, "should surface the approval hint")
    }

    func testAppliedFailedButNoApprovalFlag() {
        // setEnabled reported failure, no approval requirement — snap back, no message.
        let outcome = Reconciler.reconcile(
            desired: true, applied: false, actual: false, requiresApproval: false
        )
        XCTAssertEqual(outcome.resolvedValue, false)
        XCTAssertFalse(outcome.needsApprovalMessage)
    }

    func testDivergedAndRequiresApprovalShowsMessage() {
        // applied==true but actual diverged from desired AND approval needed.
        let outcome = Reconciler.reconcile(
            desired: false, applied: true, actual: true, requiresApproval: true
        )
        XCTAssertEqual(outcome.resolvedValue, true)
        XCTAssertTrue(outcome.needsApprovalMessage)
    }

    func testApprovalFlagIgnoredWhenStateMatched() {
        // Edge: system reports requiresApproval but state already matches desired —
        // no divergence, so no message (don't nag when it actually took).
        let outcome = Reconciler.reconcile(
            desired: true, applied: true, actual: true, requiresApproval: true
        )
        XCTAssertFalse(outcome.needsApprovalMessage)
    }
}

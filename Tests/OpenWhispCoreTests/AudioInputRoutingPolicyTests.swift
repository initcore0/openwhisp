import XCTest
@testable import OpenWhispCore

/// The pure routing decision that fixes the "selected mic silently ignored" bug.
/// The CoreAudio resolution itself is app-side (needs a live audio stack), but the
/// DECISION — empty=default, resolved=use, unresolved=error-not-fallback — is pure
/// and pinned here so a regression to silent fallback fails a unit test.
final class AudioInputRoutingPolicyTests: XCTestCase {

    func testEmptyMicIDFollowsSystemDefault() {
        // Empty selection is "follow the system default" regardless of resolution.
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "", deviceResolved: false),
            .systemDefault
        )
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "", deviceResolved: true),
            .systemDefault
        )
    }

    func testWhitespaceOnlyMicIDIsTreatedAsDefault() {
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "   ", deviceResolved: false),
            .systemDefault
        )
    }

    func testResolvedDeviceIsUsed() {
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "BlackHole-UID", deviceResolved: true),
            .useDevice(uid: "BlackHole-UID")
        )
    }

    /// The crux of the bug: a pinned device that can't be resolved must surface as
    /// `.unresolved`, NOT silently degrade to `.systemDefault`.
    func testUnresolvedPinnedDeviceDoesNotFallBackToDefault() {
        let decision = AudioInputRoutingPolicy.decide(
            microphoneID: "Disconnected-UID", deviceResolved: false)
        XCTAssertEqual(decision, .unresolved(uid: "Disconnected-UID"))
        XCTAssertNotEqual(decision, .systemDefault,
                          "an unresolved pinned device must never silently become the default")
    }

    func testMicIDIsTrimmedBeforeCarryingThroughTheDecision() {
        // A padded UID resolves/carries as its trimmed form (the resolver trims too).
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "  UID-7  ", deviceResolved: true),
            .useDevice(uid: "UID-7")
        )
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "  UID-7  ", deviceResolved: false),
            .unresolved(uid: "UID-7")
        )
    }

    func testUnresolvedMessageIsUserFacing() {
        let msg = AudioInputRoutingPolicy.unresolvedMessage(uid: "UID-7")
        XCTAssertFalse(msg.isEmpty)
        // Points the user at where to fix it, doesn't leak the raw UID.
        XCTAssertTrue(msg.contains("Settings"))
        XCTAssertFalse(msg.contains("UID-7"))
    }
}

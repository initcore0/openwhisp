import XCTest
@testable import OpenWhispCore

/// The pure routing decision behind mic selection. The CoreAudio resolution itself
/// is app-side (needs a live audio stack), but the DECISION — empty=default,
/// resolved=use, disconnected=announced-fallback-to-default — is pure and pinned
/// here. A disconnected pinned device must NOT wedge the session (the
/// AirPods-disconnect "Starting…" hang), and must carry its UID so callers can
/// announce the fallback rather than silently capturing a different mic.
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

    /// A pinned device that isn't connected falls back to the default input so the
    /// session can run — but as `.fallbackToDefault` carrying the UID (never plain
    /// `.systemDefault`), so callers must announce the fallback instead of silently
    /// capturing a different mic than the one the user picked.
    func testDisconnectedPinnedDeviceFallsBackToDefaultWithNotice() {
        let decision = AudioInputRoutingPolicy.decide(
            microphoneID: "Disconnected-UID", deviceResolved: false)
        XCTAssertEqual(decision, .fallbackToDefault(uid: "Disconnected-UID"))
        XCTAssertNotEqual(decision, .systemDefault,
                          "the fallback must stay distinguishable so it is announced, not silent")
    }

    func testMicIDIsTrimmedBeforeCarryingThroughTheDecision() {
        // A padded UID resolves/carries as its trimmed form (the resolver trims too).
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "  UID-7  ", deviceResolved: true),
            .useDevice(uid: "UID-7")
        )
        XCTAssertEqual(
            AudioInputRoutingPolicy.decide(microphoneID: "  UID-7  ", deviceResolved: false),
            .fallbackToDefault(uid: "UID-7")
        )
    }

    func testUnresolvedMessageIsUserFacing() {
        let msg = AudioInputRoutingPolicy.unresolvedMessage(uid: "UID-7")
        XCTAssertFalse(msg.isEmpty)
        // Points the user at where to fix it, doesn't leak the raw UID.
        XCTAssertTrue(msg.contains("Settings"))
        XCTAssertFalse(msg.contains("UID-7"))
    }

    func testFellBackToDefaultMirrorsTheDecision() {
        XCTAssertTrue(AudioInputRoutingPolicy.fellBackToDefault(
            microphoneID: "Disconnected-UID", deviceResolved: false))
        XCTAssertFalse(AudioInputRoutingPolicy.fellBackToDefault(
            microphoneID: "Connected-UID", deviceResolved: true))
        XCTAssertFalse(AudioInputRoutingPolicy.fellBackToDefault(
            microphoneID: "", deviceResolved: false))
    }

    func testListeningStatusAnnotatesTheFallback() {
        XCTAssertEqual(
            AudioInputRoutingPolicy.listeningStatus(micFellBackToDefault: false),
            "Listening...")
        XCTAssertTrue(
            AudioInputRoutingPolicy.listeningStatus(micFellBackToDefault: true)
                .contains("default mic"))
    }

    func testFallbackNoticeIsUserFacing() {
        let msg = AudioInputRoutingPolicy.fallbackNotice(uid: "UID-7")
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(msg.lowercased().contains("default"))
        XCTAssertFalse(msg.contains("UID-7"))
    }
}

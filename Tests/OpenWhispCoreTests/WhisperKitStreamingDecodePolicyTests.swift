import XCTest
@testable import OpenWhispCore

/// Regression guard for the WhisperKit long-dictation truncation: past ~30 s of
/// continuous speech the transcript froze and every later word was dropped.
///
/// The cause was `withoutTimestamps: true` on the streaming decode options. With
/// no timestamp tokens, `SegmentSeeker` cannot split a window, so it yields ONE
/// segment; `AudioStreamTranscriber` only confirms when
/// `segments.count > requiredSegmentsForConfirmation` (2), so nothing was ever
/// confirmed, `lastConfirmedSegmentEndSeconds` stayed at 0, and the realtime
/// loop's `clipTimestamps = [0]` re-decoded the FIRST 30 s (the encoder window)
/// on every pass, forever.
///
/// These pin the invariant so the flag can't be flipped back without a failure.
final class WhisperKitStreamingDecodePolicyTests: XCTestCase {

    /// The actual fix. If this flips to `true`, dictation truncates at 30 s.
    func testStreamingPathEmitsTimestamps() {
        XCTAssertFalse(
            WhisperKitStreamingDecodePolicy.withoutTimestamps,
            "Streaming MUST emit timestamp tokens — they are what lets segments confirm "
                + "and the decode window advance. skipSpecialTokens already keeps the "
                + "preview clean, so suppressing timestamps buys nothing and truncates "
                + "every dictation at 30 s.")
    }

    // MARK: - Why the flag matters

    func testWithoutTimestampsYieldsASingleUnconfirmableSegment() {
        XCTAssertEqual(
            WhisperKitStreamingDecodePolicy.segmentsPerWindow(timestampsEmitted: false), 1,
            "No timestamp tokens means SegmentSeeker finds no consecutive pairs and lumps "
                + "the window into one segment.")
        XCTAssertFalse(
            WhisperKitStreamingDecodePolicy.advancesConfirmedEnd(timestampsEmitted: false),
            "One segment can never exceed requiredSegmentsForConfirmation (2), so the "
                + "confirmed end stays pinned at 0.")
    }

    func testWithTimestampsTheConfirmedEndAdvances() {
        XCTAssertTrue(
            WhisperKitStreamingDecodePolicy.advancesConfirmedEnd(timestampsEmitted: true),
            "Timestamps let the window split into enough segments to confirm, which is "
                + "what moves the clip point forward with the speech.")
    }

    // MARK: - The user-visible consequence

    /// The reported symptom, stated in seconds: a stuck clip point caps a session
    /// at exactly Whisper's 30 s encoder window.
    func testStuckConfirmationCapsDictationAtTheThirtySecondWindow() {
        XCTAssertEqual(
            WhisperKitStreamingDecodePolicy.maxTranscribableSeconds(timestampsEmitted: false), 30,
            "480_000 samples @ 16 kHz — the ceiling users hit when dictating ~40-60 s.")
    }

    func testEmittingTimestampsRemovesTheCeiling() {
        XCTAssertNil(
            WhisperKitStreamingDecodePolicy.maxTranscribableSeconds(timestampsEmitted: true),
            "With confirmation advancing, dictation length is unbounded.")
    }

    /// Pin the constants the reasoning above depends on, so a WhisperKit bump
    /// that changes them surfaces here rather than as silent truncation.
    func testWindowAndConfirmationConstantsMatchWhisperKit() {
        XCTAssertEqual(WhisperKitStreamingDecodePolicy.windowSamples, 480_000)
        XCTAssertEqual(WhisperKitStreamingDecodePolicy.sampleRate, 16_000)
        XCTAssertEqual(WhisperKitStreamingDecodePolicy.requiredSegmentsForConfirmation, 2)
    }
}

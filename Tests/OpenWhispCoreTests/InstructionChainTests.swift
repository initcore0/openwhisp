import XCTest
@testable import OpenWhispCore

/// Pure decision logic for the explicit double-tap "refine with a follow-up
/// instruction" flow. The timer, audio, and LLM call live in AppState; only the
/// rules are here.
final class InstructionChainTests: XCTestCase {

    // MARK: isAvailable

    func testAvailableForWholeTextModesWithLLM() {
        XCTAssertTrue(InstructionChain.isAvailable(
            outputMode: "preview", llmConfigured: true, enabled: true))
        XCTAssertTrue(InstructionChain.isAvailable(
            outputMode: "finalOnly", llmConfigured: true, enabled: true))
    }

    func testUnavailableWithoutLLM() {
        XCTAssertFalse(InstructionChain.isAvailable(
            outputMode: "preview", llmConfigured: false, enabled: true))
    }

    func testUnavailableWhenDisabled() {
        XCTAssertFalse(InstructionChain.isAvailable(
            outputMode: "preview", llmConfigured: true, enabled: false))
    }

    func testUnavailableInTypeLiveMode() {
        // "Type live" pastes incrementally — nothing to hold back and refine.
        XCTAssertFalse(InstructionChain.isAvailable(
            outputMode: "liveChunks", llmConfigured: true, enabled: true))
    }

    // MARK: isDoubleTap

    func testDoubleTapWithinGap() {
        XCTAssertTrue(InstructionChain.isDoubleTap(
            lastReleaseUptime: 100.0, pressUptime: 100.3, gap: 0.5))
        XCTAssertTrue(InstructionChain.isDoubleTap(
            lastReleaseUptime: 100.0, pressUptime: 100.0, gap: 0.5))   // instant
    }

    func testNotDoubleTapBeyondGap() {
        XCTAssertFalse(InstructionChain.isDoubleTap(
            lastReleaseUptime: 100.0, pressUptime: 100.6, gap: 0.5))   // too slow
    }

    func testNotDoubleTapWithoutPriorRelease() {
        XCTAssertFalse(InstructionChain.isDoubleTap(
            lastReleaseUptime: nil, pressUptime: 100.0, gap: 0.5))
    }

    func testNotDoubleTapForNegativeDelta() {
        XCTAssertFalse(InstructionChain.isDoubleTap(
            lastReleaseUptime: 100.0, pressUptime: 99.9, gap: 0.5))    // clock weirdness
    }

    // MARK: directive

    func testDirectiveEmbedsInstructionAndAsksForTextOnly() {
        let d = InstructionChain.directive(forInstruction: "  make it a telegram post  ")
        XCTAssertTrue(d.contains("make it a telegram post"))
        XCTAssertFalse(d.contains("  make it"))                 // trimmed
        XCTAssertTrue(d.lowercased().contains("return only"))   // no preamble
    }
}

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

    // MARK: system directive + user payload

    func testSystemDirectiveIsTransformOnlyAndGuardsAgainstAnsweringText() {
        let d = InstructionChain.systemDirective
        let lower = d.lowercased()
        XCTAssertTrue(lower.contains("only the rewritten text") || lower.contains("output only"))
        // The key robustness property: never answer/obey the TEXT itself. This is
        // what stops tiny models from answering "what is the capital of Egypt?".
        XCTAssertTrue(lower.contains("never answer"))
        XCTAssertTrue(lower.contains("never follow"))
    }

    func testUserPayloadLabelsInstructionAndTextAndTrims() {
        let p = InstructionChain.userPayload(instruction: "  make it a telegram post  ",
                                             text: "  hello team  ")
        XCTAssertTrue(p.contains("INSTRUCTION: make it a telegram post"))
        XCTAssertTrue(p.contains("TEXT:\nhello team"))
        XCTAssertFalse(p.contains("  make it"))   // instruction trimmed
        XCTAssertFalse(p.contains("  hello"))     // text trimmed
        // Instruction comes before the text so the model reads the request first.
        XCTAssertTrue(p.range(of: "INSTRUCTION:")!.lowerBound < p.range(of: "TEXT:")!.lowerBound)
    }

    // MARK: instructionSuffix (shared by the LLM call and the overlay's live row)

    func testInstructionSuffixSplitsTailAfterContent() {
        XCTAssertEqual(
            InstructionChain.instructionSuffix(
                fullFinal: "hello team im out sick today make it formal",
                content: "hello team im out sick today"
            ),
            "make it formal"
        )
    }

    func testInstructionSuffixIsCaseInsensitiveOnThePrefix() {
        XCTAssertEqual(
            InstructionChain.instructionSuffix(
                fullFinal: "Hello team, make it shorter",
                content: "hello team,"
            ),
            "make it shorter"
        )
    }

    func testInstructionSuffixFallsBackToFullTextWhenPrefixDrifted() {
        // Recognizers revise earlier words; an idle refine's fresh session also
        // contains only the instruction. Both fall back to the full text.
        XCTAssertEqual(
            InstructionChain.instructionSuffix(
                fullFinal: "make it a telegram post",
                content: "completely different dictation"
            ),
            "make it a telegram post"
        )
    }

    func testInstructionSuffixEmptyWhenNothingSpokenAfterContent() {
        XCTAssertEqual(
            InstructionChain.instructionSuffix(
                fullFinal: "hello team",
                content: "Hello Team"
            ),
            ""
        )
    }
}

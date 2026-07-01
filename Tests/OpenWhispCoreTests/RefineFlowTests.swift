import XCTest
@testable import OpenWhispCore

/// The refine flow's whole point is to be provably correct where the old implicit
/// flags weren't. These cover the happy path plus every corner case that
/// previously wedged the overlay or mis-assigned text.
final class RefineFlowTests: XCTestCase {

    // MARK: Happy path — dictation then instruction

    func testDictationThenInstructionRunsLLMAndInserts() {
        var f = RefineFlow()
        // Re-press engages refine; step-1 already resolved (just-dictated text).
        XCTAssertEqual(f.handle(.engage(step1: "hello team", fromSelection: false)),
                       [.startInstructionCapture])
        XCTAssertTrue(f.isActive)
        // Instruction spoken.
        XCTAssertEqual(f.handle(.instructionFinalized("make it formal")),
                       [.runLLM(step1: "hello team", instruction: "make it formal")])
        XCTAssertTrue(f.isApplying)
        // LLM returns.
        XCTAssertEqual(f.handle(.llmSucceeded("Hello, team.")),
                       [.insert(text: "Hello, team.", replacingSelection: false),
                        .status("Instruction applied")])
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.state, .inactive)
    }

    // MARK: step-1 still transcribing when refine engages (WhisperKit lag)

    func testEngageWithNilStep1ThenStep1FinalizesThenInstruction() {
        var f = RefineFlow()
        XCTAssertEqual(f.handle(.engage(step1: nil, fromSelection: false)),
                       [.startInstructionCapture])
        // Step-1's late transcript arrives.
        XCTAssertEqual(f.handle(.step1Finalized("what is the capital of egypt")), [])
        // Then the instruction.
        XCTAssertEqual(f.handle(.instructionFinalized("make it polite")),
                       [.runLLM(step1: "what is the capital of egypt", instruction: "make it polite")])
    }

    // MARK: The bugs that used to wedge the overlay

    func testEmptyStep1AbandonsCleanly() {
        // Rapid/empty re-press: step-1 never produced text. Must NOT wedge.
        var f = RefineFlow()
        _ = f.handle(.engage(step1: nil, fromSelection: false))
        XCTAssertEqual(f.handle(.step1Finalized("   ")),
                       [.finishQuietly(status: "Nothing to refine")])
        XCTAssertFalse(f.isActive)
    }

    func testEmptyInstructionWithDictationInsertsStep1Unchanged() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "hello team", fromSelection: false))
        XCTAssertEqual(f.handle(.instructionFinalized("")),
                       [.insert(text: "hello team", replacingSelection: false),
                        .status("No instruction heard; inserted text")])
        XCTAssertFalse(f.isActive)
    }

    func testEmptyInstructionWithSelectionLeavesTextAlone() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "selected text", fromSelection: true))
        XCTAssertEqual(f.handle(.instructionFinalized("  ")),
                       [.finishQuietly(status: "No instruction heard")])
        XCTAssertFalse(f.isActive)
    }

    func testEmptyStep1AndEmptyInstructionAbandons() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: nil, fromSelection: false))
        // Instruction fires before step-1 ever resolves (both empty).
        XCTAssertEqual(f.handle(.instructionFinalized("")),
                       [.finishQuietly(status: "Nothing to refine")])
        XCTAssertFalse(f.isActive)
    }

    // MARK: Selection source

    func testSelectionRefineReplacesSelection() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "the quick brown fox", fromSelection: true))
        _ = f.handle(.instructionFinalized("uppercase it"))
        XCTAssertEqual(f.handle(.llmSucceeded("THE QUICK BROWN FOX")),
                       [.insert(text: "THE QUICK BROWN FOX", replacingSelection: true),
                        .status("Instruction applied")])
    }

    // MARK: LLM failure falls back to step-1

    func testLLMFailureInsertsStep1() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "hello", fromSelection: false))
        _ = f.handle(.instructionFinalized("make it formal"))
        let effects = f.handle(.llmFailed("timeout"))
        XCTAssertEqual(effects.first, .insert(text: "hello", replacingSelection: false))
        XCTAssertFalse(f.isActive)
    }

    func testLLMEmptyResultFallsBackToStep1() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "hello", fromSelection: false))
        _ = f.handle(.instructionFinalized("x"))
        XCTAssertEqual(f.handle(.llmSucceeded("   ")),
                       [.insert(text: "hello", replacingSelection: false),
                        .status("Instruction applied")])
    }

    // MARK: Abort (cancel / new dictation / watchdog)

    func testAbortWhileCapturingClearsState() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "hello", fromSelection: false))
        XCTAssertEqual(f.handle(.abort), [.finishQuietly(status: "Ready")])
        XCTAssertFalse(f.isActive)
    }

    func testAbortWhileApplyingClearsState() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "hello", fromSelection: false))
        _ = f.handle(.instructionFinalized("x"))
        XCTAssertTrue(f.isApplying)
        XCTAssertEqual(f.handle(.abort), [.finishQuietly(status: "Ready")])
        XCTAssertFalse(f.isActive)
    }

    func testAbortWhenInactiveIsNoOp() {
        var f = RefineFlow()
        XCTAssertEqual(f.handle(.abort), [])
    }

    // MARK: Rapid re-press must not stack sessions

    func testReEngageWhileCapturingReplacesRatherThanStacks() {
        var f = RefineFlow()
        _ = f.handle(.engage(step1: "first", fromSelection: false))
        // A second re-press before speaking the instruction: fresh capture, one
        // effect, state replaced (not two overlapping instruction sessions).
        XCTAssertEqual(f.handle(.engage(step1: "second", fromSelection: false)),
                       [.startInstructionCapture])
        _ = f.handle(.instructionFinalized("shorten"))
        XCTAssertTrue(f.isApplying)
        // The content refined is the latest engage's step-1.
        if case let .applying(step1, _, _) = f.state {
            XCTAssertEqual(step1, "second")
        } else {
            XCTFail("expected applying state")
        }
    }

    // MARK: Stray events in wrong states are ignored (no crashes, no side effects)

    func testStrayEventsIgnored() {
        var f = RefineFlow()
        XCTAssertEqual(f.handle(.instructionFinalized("x")), [])   // inactive
        XCTAssertEqual(f.handle(.step1Finalized("x")), [])          // inactive
        XCTAssertEqual(f.handle(.llmSucceeded("x")), [])            // inactive
        _ = f.handle(.engage(step1: "a", fromSelection: false))
        _ = f.handle(.instructionFinalized("i"))                    // -> applying
        XCTAssertEqual(f.handle(.engage(step1: "b", fromSelection: false)), []) // engage ignored while applying
        XCTAssertEqual(f.handle(.step1Finalized("late")), [])       // stray step-1 while applying
    }
}

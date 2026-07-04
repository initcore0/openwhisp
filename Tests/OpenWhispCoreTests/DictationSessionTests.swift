import XCTest
@testable import OpenWhispCore

final class DictationSessionTests: XCTestCase {

    func testUserInitiatorIsNotAgent() {
        let i = SessionInitiator.user
        XCTAssertFalse(i.isAgent)
        XCTAssertNil(i.clientName)
        XCTAssertNil(i.prompt)
    }

    func testAgentInitiatorExposesClientAndPrompt() {
        let i = SessionInitiator.agent(client: "claude-code", prompt: "Which branch?")
        XCTAssertTrue(i.isAgent)
        XCTAssertEqual(i.clientName, "claude-code")
        XCTAssertEqual(i.prompt, "Which branch?")
    }

    func testAgentInitiatorAllowsNilPrompt() {
        let i = SessionInitiator.agent(client: "openwhisp-cli", prompt: nil)
        XCTAssertTrue(i.isAgent)
        XCTAssertEqual(i.clientName, "openwhisp-cli")
        XCTAssertNil(i.prompt)
    }

    func testOutcomeEquatable() {
        XCTAssertEqual(SessionOutcome.completed(text: "hi"), .completed(text: "hi"))
        XCTAssertNotEqual(SessionOutcome.completed(text: "hi"), .completed(text: "bye"))
        XCTAssertNotEqual(SessionOutcome.empty, .cancelled)
        XCTAssertEqual(SessionOutcome.error(message: "mic"), .error(message: "mic"))
    }

    func testCompletedCarriesText() {
        // The disposition an agent waiter reads: completed → return text;
        // everything else → no transcript.
        if case let .completed(text) = SessionOutcome.completed(text: "the answer") {
            XCTAssertEqual(text, "the answer")
        } else {
            XCTFail("expected .completed")
        }
    }
}

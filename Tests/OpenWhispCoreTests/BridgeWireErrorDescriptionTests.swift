import XCTest
@testable import OpenWhispCore

/// The wire error's human message must survive Foundation's error formatting —
/// regression test for the meeting-summary status showing
/// "OpenWhisp.BridgeWire.ErrorObject error 1." instead of the real reason.
final class BridgeWireErrorDescriptionTests: XCTestCase {
    func testLocalizedDescriptionIsTheWireMessage() {
        let err = BridgeWire.ErrorObject.domain(
            .llmUnavailable, message: "built-in model unavailable")
        XCTAssertEqual(err.localizedDescription, "built-in model unavailable")
        XCTAssertEqual((err as Error).localizedDescription, "built-in model unavailable")
    }
}

import XCTest
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// Decode/encode of the typed MCP wire (JSONValue + IncomingMessage envelope).
final class MCPWireTests: XCTestCase {

    private func decode(_ json: String) throws -> MCPWire.IncomingMessage {
        try JSONDecoder().decode(MCPWire.IncomingMessage.self, from: Data(json.utf8))
    }

    // MARK: - id variants (string / number / null / absent)

    func testDecodesNumericId() throws {
        let m = try decode(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        XCTAssertEqual(m.id, .number(7))
        XCTAssertEqual(m.method, "ping")
        XCTAssertFalse(m.isNotification)
    }

    func testDecodesStringId() throws {
        let m = try decode(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        XCTAssertEqual(m.id, .string("abc"))
    }

    func testDecodesNullId() throws {
        let m = try decode(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        // An explicit null id is a present id (RPCID.null), not a notification.
        XCTAssertEqual(m.id, .null)
        XCTAssertFalse(m.isNotification)
    }

    func testAbsentIdIsNotification() throws {
        let m = try decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(m.id)
        XCTAssertTrue(m.isNotification)
    }

    // MARK: - malformed / tolerant

    func testMissingMethodFailsToDecode() {
        XCTAssertThrowsError(try decode(#"{"jsonrpc":"2.0","id":1}"#))
    }

    func testMissingJsonrpcAndParamsTolerated() throws {
        let m = try decode(#"{"id":1,"method":"ping"}"#)
        XCTAssertEqual(m.method, "ping")
        XCTAssertNil(m.params)
    }

    // MARK: - JSONValue accessors

    func testNestedObjectAndIntTolerance() throws {
        let m = try decode(#"{"id":1,"method":"tools/call","params":{"name":"openwhisp_history","arguments":{"limit":20},"_meta":{"progressToken":"t1"}}}"#)
        XCTAssertEqual(m.params?["name"]?.stringValue, "openwhisp_history")
        XCTAssertEqual(m.params?["arguments"]?["limit"]?.intValue, 20)
        XCTAssertEqual(m.params?["_meta"]?["progressToken"]?.stringValue, "t1")
    }

    func testIntValueAcceptsWholeNumberDouble() throws {
        // A client that encodes 60 as 60.0 must still read as Int 60.
        let v = try JSONDecoder().decode(MCPWire.JSONValue.self, from: Data("60.0".utf8))
        XCTAssertEqual(v.intValue, 60)
    }

    // MARK: - ToolResult encoding shape

    func testToolResultTextEncoding() throws {
        let r = MCPWire.ToolResult.text("hello")
        let data = try JSONEncoder().encode(r.asJSON)
        let back = try JSONDecoder().decode(MCPWire.JSONValue.self, from: data)
        XCTAssertEqual(back["isError"], .bool(false))
        XCTAssertEqual(back["content"]?[arrayIndex: 0]?["type"]?.stringValue, "text")
        XCTAssertEqual(back["content"]?[arrayIndex: 0]?["text"]?.stringValue, "hello")
    }
}

// Small array-subscript helper for terse assertions in tests.
private extension MCPWire.JSONValue {
    subscript(arrayIndex i: Int) -> MCPWire.JSONValue? {
        if case .array(let a) = self, a.indices.contains(i) { return a[i] }
        return nil
    }
}

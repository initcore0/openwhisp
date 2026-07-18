import XCTest
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// The pure control-plane routing (`initialize` / `ping` / `tools/list` /
/// notifications / unknown methods) resolved by `controlResponse`.
final class MCPServerDispatchTests: XCTestCase {

    private func message(_ json: String) throws -> MCPWire.IncomingMessage {
        try JSONDecoder().decode(MCPWire.IncomingMessage.self, from: Data(json.utf8))
    }

    func testInitializeEchoesProtocolVersion() throws {
        let server = MCPServer()
        let m = try message(#"{"id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code"}}}"#)
        guard case .result(let id, let value) = server.controlResponse(for: m) else {
            return XCTFail("expected result")
        }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(value["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(value["serverInfo"]?["name"]?.stringValue, "openwhisp")
    }

    func testInitializeFallsBackWhenNoVersion() throws {
        let server = MCPServer()
        let m = try message(#"{"id":1,"method":"initialize","params":{}}"#)
        guard case .result(_, let value) = server.controlResponse(for: m) else {
            return XCTFail("expected result")
        }
        XCTAssertEqual(value["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testPingReturnsEmptyObject() throws {
        let m = try message(#"{"id":"p","method":"ping"}"#)
        guard case .result(let id, let value) = MCPServer().controlResponse(for: m) else {
            return XCTFail("expected result")
        }
        XCTAssertEqual(id, .string("p"))
        XCTAssertEqual(value, .object([:]))
    }

    func testToolsListReturnsThreeTools() throws {
        let m = try message(#"{"id":1,"method":"tools/list"}"#)
        guard case .result(_, let value) = MCPServer().controlResponse(for: m),
              case .array(let tools)? = value["tools"] else {
            return XCTFail("expected tools array")
        }
        XCTAssertEqual(tools.count, 3)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), ["openwhisp_dictate", "openwhisp_refine", "openwhisp_history"])
    }

    func testDictateToolAdvertisesAutoSubmit() throws {
        // MAK-76: the dictate tool schema exposes the optional autoSubmit boolean so
        // clients (Claude Code /voice) can turn off immediate return.
        let m = try message(#"{"id":1,"method":"tools/list"}"#)
        guard case .result(_, let value) = MCPServer().controlResponse(for: m),
              case .array(let tools)? = value["tools"] else {
            return XCTFail("expected tools array")
        }
        let dictate = tools.first { $0["name"]?.stringValue == "openwhisp_dictate" }
        let props = dictate?["inputSchema"]?["properties"]
        XCTAssertEqual(props?["autoSubmit"]?["type"]?.stringValue, "boolean")
    }

    func testNotificationYieldsNoReply() throws {
        let m = try message(#"{"method":"notifications/initialized"}"#)
        XCTAssertEqual(MCPServer().controlResponse(for: m), .none)
    }

    func testUnknownMethodWithIdIsMethodNotFound() throws {
        let m = try message(#"{"id":9,"method":"frobnicate"}"#)
        guard case .error(let id, let code, _) = MCPServer().controlResponse(for: m) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(id, .number(9))
        XCTAssertEqual(code, BridgeWire.ErrorObject.methodNotFound)
    }

    func testUnknownNotificationIsSilentlyIgnored() throws {
        // No id ⇒ a notification ⇒ no error frame even for an unknown method.
        let m = try message(#"{"method":"frobnicate"}"#)
        XCTAssertEqual(MCPServer().controlResponse(for: m), .none)
    }
}

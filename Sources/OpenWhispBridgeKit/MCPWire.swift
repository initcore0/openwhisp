import Foundation
import OpenWhispCore

/// Typed JSON-RPC 2.0 message shapes for the `openwhisp mcp` stdio adapter.
///
/// The Agent Bridge wire (app ↔ CLI) is modeled by ``BridgeWire`` in
/// OpenWhispCore. The *MCP* wire (agent ↔ this adapter) is a distinct protocol,
/// but it is also JSON-RPC 2.0 and reuses ``BridgeWire``'s `RPCID`, `Request` /
/// `Response` envelopes, and `ErrorObject` so the adapter no longer hand-rolls
/// untyped `JSONSerialization` dictionaries.
///
/// MCP's `params` and `tools/call` `content` arrays are heterogeneous
/// (`{"type":"text","text":…}`, numbers, nested objects), which don't fit a
/// single fixed Codable struct. Rather than pull the whole MCP SDK, we model the
/// dynamic slots with a minimal ``JSONValue`` enum — enough to decode the request
/// params we read and to encode the result shapes MCP requires, and unit-testable
/// via `swift test`.
enum MCPWire {

    /// A minimal recursive JSON value, for the dynamically-typed slots of MCP
    /// (request `params`, `_meta`, and the heterogeneous `content` result array).
    enum JSONValue: Codable, Equatable {
        case string(String)
        case number(Double)
        case integer(Int)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let i = try? c.decode(Int.self) {
                self = .integer(i)
            } else if let d = try? c.decode(Double.self) {
                self = .number(d)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let a = try? c.decode([JSONValue].self) {
                self = .array(a)
            } else if let o = try? c.decode([String: JSONValue].self) {
                self = .object(o)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "unrepresentable JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let d): try c.encode(d)
            case .integer(let i): try c.encode(i)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }

        // MARK: - Typed accessors used when reading request params.

        /// The value under `key` if this is an object; nil otherwise.
        subscript(_ key: String) -> JSONValue? {
            if case .object(let o) = self { return o[key] }
            return nil
        }

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// An integer, tolerant of a JSON number that decoded as `.number`
        /// (e.g. `20.0`) — MCP clients aren't strict about int vs. number.
        var intValue: Int? {
            switch self {
            case .integer(let i): return i
            case .number(let d) where d == d.rounded(): return Int(d)
            default: return nil
            }
        }
    }

    /// One incoming MCP frame, decoded from a stdio line. `id` absent ⇒ it's a
    /// notification (no response is written). `params` is kept as a ``JSONValue``
    /// because each method reads a different shape.
    struct IncomingMessage: Decodable {
        var id: BridgeWire.RPCID?
        var method: String
        var params: JSONValue?

        // Tolerant decode: `method` required; `jsonrpc`/`id`/`params` optional.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.method = try c.decode(String.self, forKey: .method)
            // Distinguish an ABSENT `id` (a notification) from an explicit
            // `"id":null` (a degenerate but valid JSON-RPC request id we must echo
            // back). `decodeIfPresent` collapses both to nil, so key-presence is
            // checked first and the null is decoded through `RPCID` (→ `.null`).
            if c.contains(.id) {
                self.id = try c.decode(BridgeWire.RPCID.self, forKey: .id)
            } else {
                self.id = nil
            }
            self.params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
        }

        private enum CodingKeys: String, CodingKey { case id, method, params }

        var isNotification: Bool { id == nil }
    }

    /// The result of a `tools/call`: a content array (currently always a single
    /// text block) plus the `isError` flag. Encodes to MCP's expected shape.
    struct ToolResult: Codable, Equatable {
        var content: [ContentBlock]
        var isError: Bool

        static func text(_ text: String, isError: Bool = false) -> ToolResult {
            ToolResult(content: [ContentBlock(type: "text", text: text)], isError: isError)
        }

        var asJSON: JSONValue {
            .object([
                "content": .array(content.map(\.asJSON)),
                "isError": .bool(isError),
            ])
        }
    }

    struct ContentBlock: Codable, Equatable {
        var type: String
        var text: String

        var asJSON: JSONValue {
            .object(["type": .string(type), "text": .string(text)])
        }
    }

    // MARK: - Response encoding

    /// A JSON-RPC 2.0 response carrying a ``JSONValue`` result. Uses the same
    /// `id` echo semantics as ``BridgeWire.Response``.
    struct ResultResponse: Encodable {
        var jsonrpc = "2.0"
        var id: BridgeWire.RPCID?
        var result: JSONValue
    }

    struct ErrorResponse: Encodable {
        var jsonrpc = "2.0"
        var id: BridgeWire.RPCID?
        var error: BridgeWire.ErrorObject
    }

    /// A server→client notification (no `id`), carrying a ``JSONValue`` params.
    struct OutgoingNotification: Encodable {
        var jsonrpc = "2.0"
        var method: String
        var params: JSONValue
    }
}

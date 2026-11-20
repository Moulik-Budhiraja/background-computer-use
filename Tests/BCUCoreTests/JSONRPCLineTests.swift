import XCTest
import BCUShared

/// What `bcu mcp` answers to a line from its client.
final class JSONRPCLineTests: XCTestCase {
    func testLinesThatArentJSONAreParseErrors() {
        XCTAssertEqual(JSONRPCLine.classify("this is not json"), .invalid(code: -32700, message: "parse error: not JSON"))
        XCTAssertEqual(JSONRPCLine.classify("  "), .blank)
    }

    /// Valid JSON that isn't an object, scalars included, is an invalid request.
    func testJSONThatIsntAnObjectIsAnInvalidRequest() {
        for line in ["[1,2]", "null", "5", "\"x\"", "true"] {
            guard case .invalid(let code, _) = JSONRPCLine.classify(line) else { return XCTFail(line) }
            XCTAssertEqual(code, -32600, line)
        }
        guard case .message(let m) = JSONRPCLine.classify(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) else { return XCTFail() }
        XCTAssertEqual(m["method"] as? String, "ping")
    }
}

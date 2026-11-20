import Foundation

/// One line from an MCP client, sorted before it's handled.
public enum JSONRPCLine: Equatable {
    /// Nothing but whitespace: skipped.
    case blank
    case message(NSDictionary)
    /// Answered with this JSON-RPC error (id null).
    case invalid(code: Int, message: String)

    public static func classify(_ line: String) -> JSONRPCLine {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return .blank }
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return .invalid(code: -32700, message: "parse error: not JSON")
        }
        guard let message = parsed as? JSONObject else {
            return .invalid(code: -32600, message: "invalid request: expected a JSON-RPC object")
        }
        return .message(message as NSDictionary)
    }
}

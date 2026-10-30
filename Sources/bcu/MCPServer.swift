import Foundation
import BCUShared

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Tool calls
/// are forwarded to the running app, which holds the permissions and the display.
final class MCPServer {
    private var client: SocketClient?
    private let out = FileHandle.standardOutput
    /// This agent's session: its own display and windows in the app.
    private let sessionID = UUID().uuidString
    /// The agent's name from `initialize` (e.g. "claude-code"), for the menu bar.
    private var clientName: String?

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { continue }
            handle(message)
        }
    }

    private func send(_ object: JSONObject) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        out.write(data)
    }

    private func reply(_ id: Any, result: JSONObject) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ id: Any, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func handle(_ message: JSONObject) {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return }  // notifications need no reply
        let params = message["params"] as? JSONObject ?? [:]
        switch method {
        case "initialize":
            clientName = (params["clientInfo"] as? JSONObject)?["name"] as? String
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "background-computer-use", "version": "0.1.0"],
                "instructions": ToolCatalog.serverInstructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": ToolCatalog.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? JSONObject ?? [:]
            reply(id, result: callTool(name, arguments))
        default:
            replyError(id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func callTool(_ name: String, _ arguments: JSONObject) -> JSONObject {
        var result: ToolResult
        do {
            result = try callWithReconnect(name, arguments)
        } catch {
            result = .error("\(error). Open \(BCUPaths.appName) from Applications and grant its permissions.")
        }
        var content: [JSONObject] = [["type": "text", "text": result.text]]
        for image in result.images {
            content.append(["type": "image", "data": image.base64, "mimeType": image.mime])
        }
        return ["content": content, "isError": result.isError]
    }

    private func callWithReconnect(_ name: String, _ arguments: JSONObject) throws -> ToolResult {
        for attempt in 0..<2 {
            do {
                if client == nil { client = try connect() }
                var args = arguments
                args["_session"] = sessionID
                if let clientName { args["_client"] = clientName }
                return try client!.call(tool: name, args: args)
            } catch {
                client = nil
                if attempt == 1 { throw error }
            }
        }
        throw SocketError.notRunning
    }
}

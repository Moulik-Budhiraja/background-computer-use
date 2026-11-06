import Foundation
import BCUShared

/// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Tool calls
/// are forwarded to the running app, which holds the permissions and the display.
final class MCPServer {
    private let out = FileHandle.standardOutput
    private let outLock = NSLock()
    /// One per session on this connection: its calls run in order on its
    /// own connection to the app, so one agent waiting (for a free display,
    /// or for another agent to finish typing in the same app) never holds
    /// up another's calls.
    private final class Lane {
        let queue: DispatchQueue
        var client: SocketClient?
        init(_ session: String) { queue = DispatchQueue(label: "bcu.mcp.\(session)") }
    }
    private var lanes: [String: Lane] = [:]
    /// This agent's session: its own display and windows in the app.
    private let sessionID: String
    /// The host app that shows this session in its own UI (`--host`).
    private let host: String?
    /// The session's name in the UI (`--label`), instead of the client's.
    private let label: String?
    /// The engine's own tool list and instructions, when it has them: a host
    /// app's `bcu` may talk to an engine of another version.
    private var catalog: (tools: [JSONObject], instructions: String)?
    /// The agent's name from `initialize` (e.g. "claude-code"), for the menu bar.
    private var clientName: String?
    /// Claude Code subagents share this connection; this tells their calls apart.
    private let subagents = SubagentLookup()
    /// The first Codex thread seen on this connection: the main agent's.
    private var mainThread: String?

    static let appVersion = BCUVersion.current

    init(host: String?, session: String?, label: String?) {
        self.host = host
        self.label = label
        sessionID = session ?? UUID().uuidString
    }

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
        outLock.lock()
        out.write(data)
        outLock.unlock()
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
            catalog = Self.engineCatalog()
            reply(id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "background-computer-use", "version": Self.appVersion],
                "instructions": catalog?.instructions ?? ToolCatalog.serverInstructions,
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": catalog?.tools ?? ToolCatalog.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? JSONObject ?? [:]
            let caller = callerSession(params["_meta"] as? JSONObject ?? [:])
            // Maintenance and test tools are for `bcu call` on a debug run only.
            if name.hasPrefix("admin_") {
                reply(id, result: ["content": [["type": "text", "text": "unknown tool \(name)"]], "isError": true])
                return
            }
            let lane = lanes[caller] ?? Lane(caller)
            lanes[caller] = lane
            lane.queue.async {
                self.reply(id, result: self.callTool(name, arguments, session: caller, lane: lane))
            }
        default:
            replyError(id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// The session a call belongs to. Every agent gets its own (its own
    /// display and windows), subagents included: a subagent's session is
    /// this connection's with its ID added.
    private func callerSession(_ meta: JSONObject) -> String {
        if let toolUse = meta["claudecode/toolUseId"] as? String, let agent = subagents?.agent(for: toolUse) {
            return "\(sessionID)/\(agent)"
        }
        if let thread = meta["threadId"] as? String {
            if mainThread == nil { mainThread = thread }
            if thread != mainThread { return "\(sessionID)/\(thread)" }
        }
        return sessionID
    }

    private func callTool(_ name: String, _ arguments: JSONObject, session: String, lane: Lane) -> JSONObject {
        var result: ToolResult
        do {
            result = try callWithReconnect(name, arguments, session: session, lane: lane)
        } catch {
            result = .error("\(error). Open \(ownerName) and grant its permissions.")
        }
        var content: [JSONObject] = [["type": "text", "text": result.text]]
        for image in result.images {
            content.append(["type": "image", "data": image.base64, "mimeType": image.mime])
        }
        return ["content": content, "isError": result.isError]
    }

    /// The running engine's tools and instructions, if it's up and new enough to say.
    private static func engineCatalog() -> (tools: [JSONObject], instructions: String)? {
        guard let client = try? SocketClient(), let reply = try? client.request(["op": "catalog"]),
              reply["ok"] as? Bool == true, let tools = reply["tools"] as? [JSONObject],
              let instructions = reply["instructions"] as? String else { return nil }
        return (tools, instructions)
    }

    private func callWithReconnect(_ name: String, _ arguments: JSONObject, session: String, lane: Lane) throws -> ToolResult {
        for attempt in 0..<2 {
            do {
                if lane.client == nil { lane.client = try connect() }
                var args = arguments
                args["_session"] = session
                if session != sessionID { args["_parent"] = sessionID }
                if let clientName { args["_client"] = clientName }
                if let host { args["_host"] = host }
                if let label { args["_label"] = label }
                return try lane.client!.call(tool: name, args: args)
            } catch {
                lane.client = nil
                if attempt == 1 { throw error }
            }
        }
        throw SocketError.notRunning
    }
}

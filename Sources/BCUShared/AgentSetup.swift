import Foundation

/// The coding agents Background Computer Use can be added to.
public enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// Adds the MCP server and the skill to Claude Code and Codex. Used by the
/// app's setup window and by `bcu install-skill`.
public enum AgentSetup {
    public static let serverName = "background-computer-use"
    public static let skillName = "background-computer-use"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The agent's config folder exists, so it has been run on this Mac.
    public static func isInstalled(_ agent: AgentKind) -> Bool {
        let fm = FileManager.default
        switch agent {
        case .claude:
            return fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
                || fm.fileExists(atPath: claudeConfig.path)
        case .codex:
            return fm.fileExists(atPath: home.appendingPathComponent(".codex").path)
        }
    }

    public static func skillDirectory(_ agent: AgentKind) -> URL {
        let root = agent == .claude ? ".claude/skills" : ".codex/skills"
        return home.appendingPathComponent(root).appendingPathComponent(skillName)
    }

    /// Copy the skill folder (the one holding SKILL.md) into the agent's skills folder.
    @discardableResult
    public static func installSkill(from source: URL, for agent: AgentKind) throws -> URL {
        let fm = FileManager.default
        let dest = skillDirectory(agent)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// The agent has the skill and an MCP server entry pointing at `bcuPath`.
    public static func isConnected(_ agent: AgentKind, bcuPath: String) -> Bool {
        FileManager.default.fileExists(atPath: skillDirectory(agent).appendingPathComponent("SKILL.md").path)
            && mcpCommand(agent) == bcuPath
    }

    /// Add or update the MCP server entry so it runs `bcuPath mcp`.
    public static func addMCPServer(_ agent: AgentKind, bcuPath: String) throws {
        if mcpCommand(agent) == bcuPath { return }
        switch agent {
        case .claude: try addClaudeServer(bcuPath: bcuPath)
        case .codex: try addCodexServer(bcuPath: bcuPath)
        }
    }

    // MARK: Claude Code

    static var claudeConfig: URL { home.appendingPathComponent(".claude.json") }

    /// The command of the user-scoped server in ~/.claude.json, read only.
    static func claudeCommand() -> String? {
        guard let data = try? Data(contentsOf: claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let server = servers[serverName] as? [String: Any] else { return nil }
        return server["command"] as? String
    }

    /// Claude Code rewrites ~/.claude.json while it runs, so the entry is
    /// changed through its own CLI instead of editing the file.
    static func addClaudeServer(bcuPath: String) throws {
        // A login shell picks up the user's PATH; the extra folders cover the
        // usual install locations in case the profile doesn't add them.
        let script = """
        export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"
        command -v claude >/dev/null 2>&1 || exit 127
        claude mcp remove --scope user \(serverName) >/dev/null 2>&1
        claude mcp add --scope user \(serverName) -- "$0" mcp
        """
        let (status, output) = run("/bin/zsh", ["-lc", script, bcuPath])
        if status == 127 { throw SetupError("Couldn't find the claude command.") }
        if status != 0 { throw SetupError(output.isEmpty ? "claude mcp add failed (\(status))." : output) }
    }

    // MARK: Codex

    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    static let codexHeaders = ["[mcp_servers.\(serverName)]", "[mcp_servers.\"\(serverName)\"]"]

    /// The `command` of our table in ~/.codex/config.toml.
    static func codexCommand() -> String? {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return nil }
        var inTable = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTable = codexHeaders.contains(line); continue }
            guard inTable, line.hasPrefix("command") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return tomlUnquote(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Replace our table's lines, or append the table. Other tables, including
    /// subtables like `[mcp_servers.background-computer-use.env]`, are kept.
    static func addCodexServer(bcuPath: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        let table = [codexHeaders[0], "command = \(tomlQuote(bcuPath))", "args = [\"mcp\"]"]

        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { codexHeaders.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            // Keep blank lines and comments that separate us from the next table.
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.replaceSubrange(start..<end, with: table)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += table
        }
        let out = lines.joined(separator: "\n") + (lines.last?.isEmpty == false ? "\n" : "")
        try out.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static func tomlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tomlUnquote(_ s: String) -> String {
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 { return String(s.dropFirst().dropLast()) }
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Helpers

    static func mcpCommand(_ agent: AgentKind) -> String? {
        agent == .claude ? claudeCommand() : codexCommand()
    }

    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, text)
    }
}

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

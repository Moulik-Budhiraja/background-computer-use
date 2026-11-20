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

    /// The text to set the agent up by hand: Claude Code's command, or the
    /// table for Codex's config.toml.
    public static func manualSetup(_ agent: AgentKind, bcuPath: String) -> String {
        switch agent {
        case .claude: return "claude mcp add --scope user \(serverName) -- \"\(bcuPath)\" mcp"
        case .codex: return "[mcp_servers.\(serverName)]\ncommand = \(CodexTOML.quote(bcuPath))\nargs = [\"mcp\"]"
        }
    }

    /// The app is running from somewhere it won't stay: a disk image, or the
    /// read-only copy macOS runs an app from when it's opened where it was
    /// downloaded (App Translocation). An agent set up now would point at a
    /// path that's gone once the app is moved or the disk is ejected.
    public static func isTemporaryLocation(_ bundleURL: URL) -> Bool {
        if bundleURL.path.contains("/AppTranslocation/") { return true }
        return (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// Point agents whose server runs a `bcu` that no longer exists (the app
    /// was moved or reinstalled elsewhere) at `bcuPath`. Only entries that ran
    /// a bcu inside an app are touched. Returns the agents it fixed.
    @discardableResult
    public static func repairMovedServers(bcuPath: String) -> [AgentKind] {
        AgentKind.allCases.filter { agent in
            guard let command = mcpCommand(agent), command != bcuPath,
                  command.hasSuffix(".app/Contents/MacOS/bcu"),
                  !FileManager.default.fileExists(atPath: command) else { return false }
            return (try? addMCPServer(agent, bcuPath: bcuPath)) != nil
        }
    }

    // MARK: Claude Code

    static var claudeConfig: URL { home.appendingPathComponent(".claude.json") }

    /// The user-scoped server in ~/.claude.json, read only.
    static func claudeServer() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return nil }
        return servers[serverName] as? [String: Any]
    }

    static func claudeCommand() -> String? { claudeServer()?["command"] as? String }

    /// Claude Code rewrites ~/.claude.json while it runs, so the entry is
    /// changed through its own CLI instead of editing the file.
    static func addClaudeServer(bcuPath: String) throws {
        guard let found = findClaude() else {
            throw SetupError("Couldn't find the claude command. Run the command below in Terminal instead.")
        }
        // `claude` is often a node script, so node has to be on PATH too.
        var env = ProcessInfo.processInfo.environment
        let dir = (found.path as NSString).deletingLastPathComponent
        env["PATH"] = ([dir] + found.shellPath + claudeSearchDirs() + [env["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        func claude(_ args: [String]) -> (Int32, String) {
            run(found.path, ["mcp"] + args, environment: env, timeout: 30)
        }
        func failure(_ what: String, _ result: (Int32, String)) -> SetupError {
            SetupError(result.1.isEmpty ? "claude mcp \(what) failed (\(result.0))." : result.1)
        }

        guard let old = claudeServer() else {
            let added = claude(["add", "--scope", "user", serverName, "--", bcuPath, "mcp"])
            if added.0 != 0 { throw failure("add", added) }
            return
        }
        // There's no update command, so remove and add again, keeping anything
        // else set on the entry (like env), and put the old one back if the
        // add fails.
        var new = old
        new["command"] = bcuPath
        new["args"] = ["mcp"]
        guard let oldJSON = jsonString(old), let newJSON = jsonString(new) else {
            throw SetupError("Couldn't read the existing \(serverName) entry in ~/.claude.json.")
        }
        let removed = claude(["remove", "--scope", "user", serverName])
        if removed.0 != 0 { throw failure("remove", removed) }
        let added = claude(["add-json", "--scope", "user", serverName, newJSON])
        if added.0 != 0 {
            _ = claude(["add-json", "--scope", "user", serverName, oldJSON])
            throw failure("add-json", added)
        }
    }

    static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Where `claude` is, and the PATH the user's shell sets up.
    static func findClaude() -> (path: String, shellPath: [String])? {
        // An interactive login shell reads .zshrc (or .bashrc, or fish's
        // config), where nvm, volta, asdf and fnm put themselves on PATH.
        let marker = "__BCU_PATH__="
        let (_, output) = run(loginShell(), ["-ilc", "command -v claude; echo \"\(marker)$PATH\""], timeout: 10)
        let parsed = parseShellLookup(output, marker: marker)
        if let path = parsed.claude.map(expandTilde), isProgram(path) {
            return (path, parsed.path)
        }
        for dir in parsed.path + claudeSearchDirs() {
            let path = dir + "/claude"
            if isProgram(path) { return (path, parsed.path) }
        }
        return nil
    }

    /// Reads `command -v claude` and the PATH line out of an interactive
    /// shell's output, which can have anything else the profile prints
    /// around them. `command -v` answers with a path, or an alias's text.
    static func parseShellLookup(_ output: String, marker: String) -> (claude: String?, path: [String]) {
        var claude: String?
        var path: [String] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: marker) {
                // Colons split PATH, and a directory can have a space in it.
                // Fish prints its PATH split by spaces instead.
                let value = line[r.upperBound...]
                let separator: Character = value.contains(":") ? ":" : " "
                path = value.split(separator: separator).map(String.init).filter { $0.hasPrefix("/") }
            } else if line.hasPrefix("/") || line.hasPrefix("~/") {
                claude = line
            } else if line.hasPrefix("alias claude=") || line.hasPrefix("claude=") {
                var value = String(line[line.index(after: line.firstIndex(of: "=")!)...])
                if value.count >= 2, let q = value.first, q == "'" || q == "\"", value.last == q {
                    value = String(value.dropFirst().dropLast())
                }
                // Just the command, not any flags the alias adds.
                if let first = firstWord(value), first.hasPrefix("/") || first.hasPrefix("~/") {
                    claude = first
                }
            }
        }
        return (claude, path)
    }

    /// The first word of a shell command, with its quotes and backslashes
    /// undone: `"/opt/Claude Code/claude" --verbose` gives the path.
    static func firstWord(_ command: String) -> String? {
        var word = "", quote: Character? = nil, escaped = false, started = false
        for c in command {
            if escaped { word.append(c); escaped = false; continue }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" { escaped = true } else { word.append(c) }
                continue
            }
            switch c {
            case "\\": escaped = true; started = true
            case "\"", "'": quote = c; started = true
            case " ", "\t": if started { return word }
            default: word.append(c); started = true
            }
        }
        return started ? word : nil
    }

    /// A file that can be run.
    static func isProgram(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
    }

    /// The user's shell, as Terminal would start it.
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    /// Where installers and version managers put `claude`, for when the
    /// shell doesn't say.
    static func claudeSearchDirs() -> [String] {
        let h = home.path
        var dirs = [".local/bin", ".claude/local", ".volta/bin", ".bun/bin", ".npm-global/bin", ".npm/bin",
                    ".asdf/shims", ".local/share/mise/shims", ".local/share/fnm/aliases/default/bin",
                    "Library/Application Support/fnm/aliases/default/bin", ".fnm/aliases/default/bin",
                    "Library/pnpm", ".yarn/bin"].map { h + "/" + $0 }
        // nvm keeps one folder per node version; newest first.
        let nvm = h + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm + "/" + $0 + "/bin" }
        return dirs + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    // MARK: Codex

    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    /// The `command` of our server in ~/.codex/config.toml.
    static func codexCommand() -> String? {
        guard let text = try? String(contentsOf: resolvingSymlinks(codexConfig), encoding: .utf8) else { return nil }
        return CodexTOML.command(in: text, server: serverName)
    }

    /// Set our server's command and args, keeping everything else in the
    /// file. A file it can't read or follow is left alone.
    static func addCodexServer(bcuPath: String) throws {
        let fm = FileManager.default
        // Write through a symlinked config (dotfiles) rather than replacing the link.
        let url = resolvingSymlinks(codexConfig)
        var text = ""
        var permissions: Any?
        if fm.fileExists(atPath: url.path) {
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw SetupError("Couldn't read \(url.path), so it was left as it was. Add the table below to it yourself.")
            }
            permissions = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]
        }
        let out: String
        do {
            out = try CodexTOML.settingServer(in: text, name: serverName, command: bcuPath, args: ["mcp"])
        } catch {
            throw SetupError("Couldn't follow \(url.path) (\(error)), so it was left as it was. Add the table below to it yourself.")
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, atomically: true, encoding: .utf8)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    /// Follows symlinks to the file they end at, even one that doesn't exist yet.
    static func resolvingSymlinks(_ url: URL) -> URL {
        var path = url.path
        for _ in 0..<16 {
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { break }
            path = dest.hasPrefix("/") ? dest
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: Helpers

    static func mcpCommand(_ agent: AgentKind) -> String? {
        agent == .claude ? claudeCommand() : codexCommand()
    }

    /// Runs a command and returns its status and combined output. One that
    /// doesn't exit within `timeout` is killed and reported as timed out.
    static func run(_ path: String, _ args: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 30) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let environment { p.environment = environment }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var data = Data()
        let eof = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                lock.lock(); data.append(chunk); lock.unlock()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "\(error)")
        }
        let name = (path as NSString).lastPathComponent
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-2, "\(name) didn't finish within \(Int(timeout)) seconds.")
        }
        // Something the command started in the background can keep the pipe
        // open after it exits, so don't wait long for the end of the output.
        _ = eof.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let out = data; lock.unlock()
        let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, text)
    }
}

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

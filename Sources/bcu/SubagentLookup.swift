import Foundation

/// Tells which Claude Code subagent made a tool call.
///
/// Subagents run inside their parent's process and share its MCP connection,
/// so every call arrives on the same `bcu mcp`. Claude Code doesn't say which
/// agent a call is from, but it does tag each call with its tool-use ID
/// (`_meta["claudecode/toolUseId"]`), and it writes that ID to the calling
/// agent's transcript before the call is made: the main agent's at
/// `projects/<dir>/<session>.jsonl`, each subagent's at
/// `projects/<dir>/<session>/subagents/agent-<id>.jsonl`. This reads only what
/// was added to those files since the last call and remembers which file
/// every tool-use ID showed up in.
///
/// If anything about that layout changes, lookups find nothing and every
/// call counts as the main agent's, which is how it worked before.
final class SubagentLookup {
    private let projects: URL
    private let session: String
    private var offsets: [String: UInt64] = [:]
    /// Tool-use ID to subagent ID, or "" for the main agent.
    private var owners: [String: String] = [:]
    private var sessionDirs: [URL] = []
    private var lastDirScanMs = 0.0

    /// nil outside Claude Code.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let session = environment["CLAUDE_CODE_SESSION_ID"], !session.isEmpty else { return nil }
        self.session = session
        let config = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        projects = config.appendingPathComponent("projects")
    }

    /// The subagent that made the call with this tool-use ID, or nil for the
    /// main agent (or when it can't be told). Waits up to `waitMs` for the
    /// transcript write to land.
    func agent(for toolUseID: String, waitMs: Double = 400) -> String? {
        let deadline = Self.nowMs() + waitMs
        while true {
            if let owner = owners[toolUseID] { return owner.isEmpty ? nil : owner }
            scan()
            if let owner = owners[toolUseID] { return owner.isEmpty ? nil : owner }
            if Self.nowMs() >= deadline { return nil }
            usleep(10_000)
        }
    }

    private func scan() {
        let fm = FileManager.default
        // The project folder is named after the working directory, mangled;
        // find the one holding this session rather than guess the mangling.
        if sessionDirs.isEmpty || Self.nowMs() - lastDirScanMs > 5000 {
            lastDirScanMs = Self.nowMs()
            let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            sessionDirs = dirs.filter { fm.fileExists(atPath: $0.appendingPathComponent("\(session).jsonl").path) }
        }
        for dir in sessionDirs {
            // Subagents first: their IDs never appear in the main transcript,
            // but read them first anyway so a stray mention can't win.
            let subagents = dir.appendingPathComponent(session).appendingPathComponent("subagents")
            for file in (try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
                read(file, owner: String(name.dropFirst("agent-".count).dropLast(".jsonl".count)))
            }
            read(dir.appendingPathComponent("\(session).jsonl"), owner: "")
        }
    }

    /// Note every tool-use ID added to `file` since the last read.
    private func read(_ file: URL, owner: String) {
        let path = file.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        // A long main transcript: only its recent end can hold a live call.
        var offset = offsets[path] ?? (size > 512_000 ? size - 512_000 : 0)
        if offset > size { offset = 0 }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return }
        // Only whole lines; a line still being written is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...lastNewline]
        offsets[path] = offset + UInt64(chunk.count)
        for id in Self.toolUseIDs(in: chunk) where owners[id] == nil {
            owners[id] = owner
        }
    }

    /// Every `toolu_…` token in the bytes.
    static func toolUseIDs(in data: Data) -> [String] {
        let prefix = Array("toolu_".utf8)
        var ids: [String] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + prefix.count < bytes.count {
            if bytes[i] == prefix[0] && (1..<prefix.count).allSatisfy({ bytes[i + $0] == prefix[$0] }) {
                var j = i + prefix.count
                while j < bytes.count, Self.isIDByte(bytes[j]) { j += 1 }
                if j - i > prefix.count + 8, let s = String(bytes: bytes[i..<j], encoding: .utf8) { ids.append(s) }
                i = j
            } else {
                i += 1
            }
        }
        return ids
    }

    private static func isIDByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }

    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

import XCTest
@testable import BCUShared

/// Codex won't start with a config.toml it can't load, so the editor must
/// find our server however it's written and change nothing else.
final class CodexTOMLTests: XCTestCase {
    private let server = "background-computer-use"
    private let bcu = "/Applications/Background Computer Use.app/Contents/MacOS/bcu"
    private let old = "/Volumes/Background Computer Use/Background Computer Use.app/Contents/MacOS/bcu"

    private func set(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let out = try CodexTOML.settingServer(in: text, name: server, command: bcu, args: ["mcp"])
        // Whatever it writes must read back, with our command.
        XCTAssertEqual(CodexTOML.command(in: out, server: server), bcu, "reads back", file: file, line: line)
        // And setting it again changes nothing.
        XCTAssertEqual(try CodexTOML.settingServer(in: out, name: server, command: bcu, args: ["mcp"]), out,
                       "idempotent", file: file, line: line)
        return out
    }

    private func headerCount(_ text: String) throws -> Int {
        try CodexTOML.parse(text).headers.filter { $0.path == ["mcp_servers", server] }.count
    }

    // MARK: New file, new table

    func testEmptyFileGetsTheTable() throws {
        XCTAssertEqual(try set(""), """
        [mcp_servers.background-computer-use]
        command = "\(bcu)"
        args = ["mcp"]

        """)
    }

    func testAppendsAfterOtherTablesWithOneBlankLine() throws {
        let text = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"\n\n\n"
        XCTAssertEqual(try set(text), """
        model = "o3"

        [mcp_servers.other]
        command = "x"

        [mcp_servers.background-computer-use]
        command = "\(bcu)"
        args = ["mcp"]

        """)
    }

    func testAppendsToFileWithoutFinalNewline() throws {
        let out = try set("model = \"o3\"")
        XCTAssertTrue(out.hasPrefix("model = \"o3\"\n\n[mcp_servers.background-computer-use]\n"))
    }

    // MARK: Table form

    func testUpdatesTableInPlace() throws {
        let text = """
        [mcp_servers.background-computer-use]
        command = "\(old)"
        args = ["mcp"]

        [profiles.fast]
        model = "o4-mini"

        """
        XCTAssertEqual(try set(text), text.replacingOccurrences(of: old, with: bcu))
    }

    func testHeaderWithTrailingComment() throws {
        let text = """
        [mcp_servers.background-computer-use] # added by the app
        command = "\(old)"
        args = ["mcp"]

        """
        let out = try set(text)
        XCTAssertEqual(out, text.replacingOccurrences(of: old, with: bcu))
        XCTAssertEqual(try headerCount(out), 1)
    }

    func testHeaderWithSpacesAndQuotedKey() throws {
        let text = "[ mcp_servers . \"background-computer-use\" ]\ncommand = '\(old)'\nargs = [ \"mcp\" ]\n"
        let out = try set(text)
        XCTAssertEqual(out, "[ mcp_servers . \"background-computer-use\" ]\ncommand = \"\(bcu)\"\nargs = [\"mcp\"]\n")
        XCTAssertEqual(try headerCount(out), 1)
    }

    func testIndentedHeader() throws {
        let text = "  [mcp_servers.background-computer-use]\n  command = \"\(old)\"\n"
        let out = try set(text)
        XCTAssertEqual(out, "  [mcp_servers.background-computer-use]\n  command = \"\(bcu)\"\nargs = [\"mcp\"]\n")
    }

    func testKeepsExtraKeysCommentsAndSubtables() throws {
        let text = """
        # My Codex config
        [mcp_servers.background-computer-use]
        # the engine
        command = "\(old)" # moved later
        args = ["mcp", "--verbose"]
        startup_timeout_sec = 30
        enabled = true

        [mcp_servers.background-computer-use.env]
        BCU_LOG = "1"

        """
        let expected = """
        # My Codex config
        [mcp_servers.background-computer-use]
        # the engine
        command = "\(bcu)" # moved later
        args = ["mcp"]
        startup_timeout_sec = 30
        enabled = true

        [mcp_servers.background-computer-use.env]
        BCU_LOG = "1"

        """
        XCTAssertEqual(try set(text), expected)
    }

    func testMultilineArgsAreReplacedWhole() throws {
        let text = """
        [mcp_servers.background-computer-use]
        command = "\(old)"
        args = [
          "mcp", # the subcommand
          "--x",
        ]
        env = { A = "1" }

        """
        XCTAssertEqual(try set(text), """
        [mcp_servers.background-computer-use]
        command = "\(bcu)"
        args = ["mcp"]
        env = { A = "1" }

        """)
    }

    func testAddsMissingKeysToExistingTable() throws {
        let text = "[mcp_servers.background-computer-use]\nenv = { A = \"1\" }\n\n[other]\nx = 1\n"
        XCTAssertEqual(try set(text), """
        [mcp_servers.background-computer-use]
        command = "\(bcu)"
        args = ["mcp"]
        env = { A = "1" }

        [other]
        x = 1

        """)
    }

    func testAddsArgsAfterCommand() throws {
        let text = "[mcp_servers.background-computer-use]\ncommand = \"\(old)\"\ncwd = \"/tmp\"\n"
        XCTAssertEqual(try set(text),
                       "[mcp_servers.background-computer-use]\ncommand = \"\(bcu)\"\nargs = [\"mcp\"]\ncwd = \"/tmp\"\n")
    }

    func testTableAtEndWithoutNewline() throws {
        let text = "[mcp_servers.background-computer-use]"
        XCTAssertEqual(try set(text), "[mcp_servers.background-computer-use]\ncommand = \"\(bcu)\"\nargs = [\"mcp\"]\n")
    }

    // MARK: CRLF

    func testCRLFKeepsLineEndings() throws {
        let text = "model = \"o3\"\r\n\r\n[mcp_servers.background-computer-use]\r\ncommand = \"\(old)\"\r\nargs = [\"mcp\"]\r\n"
        let out = try set(text)
        XCTAssertEqual(out, text.replacingOccurrences(of: old, with: bcu))
        XCTAssertEqual(try headerCount(out), 1)
    }

    func testCRLFNewTableUsesCRLF() throws {
        let out = try set("model = \"o3\"\r\n")
        XCTAssertEqual(out, "model = \"o3\"\r\n\r\n[mcp_servers.background-computer-use]\r\ncommand = \"\(bcu)\"\r\nargs = [\"mcp\"]\r\n")
    }

    func testCRLFAddsMissingArgsWithCRLF() throws {
        let text = "[mcp_servers.background-computer-use]\r\ncommand = \"\(old)\"\r\n"
        XCTAssertEqual(try set(text), "[mcp_servers.background-computer-use]\r\ncommand = \"\(bcu)\"\r\nargs = [\"mcp\"]\r\n")
    }

    // MARK: Dotted keys

    func testDottedKeysUnderMcpServers() throws {
        let text = """
        [mcp_servers]
        background-computer-use.command = "\(old)"
        background-computer-use.args = ["mcp"]
        other.command = "y"

        """
        let out = try set(text)
        XCTAssertEqual(out, text.replacingOccurrences(of: old, with: bcu))
        XCTAssertEqual(try headerCount(out), 0)
    }

    func testDottedKeysAtRoot() throws {
        let text = "mcp_servers.\"background-computer-use\".command = \"\(old)\"\n\n[profiles.x]\nmodel = \"o3\"\n"
        XCTAssertEqual(try set(text), """
        mcp_servers."background-computer-use".command = "\(bcu)"
        mcp_servers.background-computer-use.args = ["mcp"]

        [profiles.x]
        model = "o3"

        """)
    }

    func testDottedKeysForOtherFieldsOnly() throws {
        let text = "[mcp_servers]\nbackground-computer-use.env.A = \"1\"\n"
        let out = try set(text)
        XCTAssertEqual(out, """
        [mcp_servers]
        background-computer-use.env.A = "1"
        background-computer-use.command = "\(bcu)"
        background-computer-use.args = ["mcp"]

        """)
        XCTAssertEqual(try headerCount(out), 0)
    }

    func testOnlyASubtableOfTheServer() throws {
        let text = "[mcp_servers.background-computer-use.env]\nA = \"1\"\n"
        XCTAssertEqual(try set(text), """
        [mcp_servers.background-computer-use.env]
        A = "1"

        [mcp_servers.background-computer-use]
        command = "\(bcu)"
        args = ["mcp"]

        """)
    }

    // MARK: Inline tables

    func testInlineTable() throws {
        let text = """
        [mcp_servers]
        background-computer-use = { command = "\(old)", args = ["mcp"], env = { A = "1" } } # ours
        other = { command = "y" }

        """
        let out = try set(text)
        XCTAssertEqual(out, text.replacingOccurrences(of: old, with: bcu))
        XCTAssertEqual(try headerCount(out), 0)
    }

    func testInlineTableAtRoot() throws {
        let text = "mcp_servers.background-computer-use = { command = \"\(old)\" }\n"
        XCTAssertEqual(try set(text), "mcp_servers.background-computer-use = { command = \"\(bcu)\", args = [\"mcp\"] }\n")
    }

    func testInlineTableMissingBoth() throws {
        let text = "[mcp_servers]\nbackground-computer-use = { env = { A = \"1\" } }\n"
        XCTAssertEqual(try set(text),
                       "[mcp_servers]\nbackground-computer-use = { command = \"\(bcu)\", args = [\"mcp\"], env = { A = \"1\" } }\n")
    }

    func testEmptyInlineTable() throws {
        let text = "[mcp_servers]\nbackground-computer-use = {}\n"
        XCTAssertEqual(try set(text), "[mcp_servers]\nbackground-computer-use = { command = \"\(bcu)\", args = [\"mcp\"] }\n")
    }

    func testNestedInlineTables() throws {
        let text = "mcp_servers = { other = { command = \"y\" }, background-computer-use = { command = \"\(old)\", args = [] } }\n"
        XCTAssertEqual(try set(text),
                       "mcp_servers = { other = { command = \"y\" }, background-computer-use = { command = \"\(bcu)\", args = [\"mcp\"] } }\n")
    }

    func testAddsToInlineMcpServersInsteadOfAHeader() throws {
        // A [mcp_servers.x] header can't add to a table that's inline.
        let text = "mcp_servers = { other = { command = \"y\" } }\n"
        let out = try set(text)
        XCTAssertEqual(out, "mcp_servers = { background-computer-use = { command = \"\(bcu)\", args = [\"mcp\"] }, other = { command = \"y\" } }\n")
        XCTAssertEqual(try headerCount(out), 0)
    }

    // MARK: Repairs and refusals

    func testRemovesDuplicateTableFromEarlierVersion() throws {
        // What the old editor left: it missed the commented header and appended another.
        let text = """
        [mcp_servers.background-computer-use] # mine
        command = "\(old)"
        args = ["mcp"]
        env = { A = "1" }

        [mcp_servers.background-computer-use]
        command = "\(old)"
        args = ["mcp"]

        """
        let out = try set(text)
        XCTAssertEqual(try headerCount(out), 1)
        XCTAssertEqual(out, """
        [mcp_servers.background-computer-use] # mine
        command = "\(bcu)"
        args = ["mcp"]
        env = { A = "1" }


        """)
    }

    func testRefusesFileItCantParse() {
        XCTAssertThrowsError(try CodexTOML.settingServer(in: "model = \"unterminated\n", name: server, command: bcu, args: ["mcp"]))
        XCTAssertThrowsError(try CodexTOML.settingServer(in: "[mcp_servers\n", name: server, command: bcu, args: ["mcp"]))
        XCTAssertThrowsError(try CodexTOML.settingServer(in: "just words\n", name: server, command: bcu, args: ["mcp"]))
    }

    func testRefusesWhenMcpServersIsNotATable() {
        XCTAssertThrowsError(try CodexTOML.settingServer(in: "mcp_servers = 3\n", name: server, command: bcu, args: ["mcp"]))
    }

    // MARK: Other TOML it must step over

    func testLeavesOtherValuesAlone() throws {
        let text = #"""
        title = """
        [mcp_servers.background-computer-use]
        not a table \
          still the string"""
        path = 'C:\Users\x'
        when = 1979-05-27 07:32:00Z
        nums = [1, 2.5, -3, +inf, 0x1F]
        [[profiles]]
        command = "not ours"
        [mcp_servers.background-computer-use]
        command = "\#(old)"

        """#
        let out = try set(text)
        XCTAssertEqual(try headerCount(out), 1)
        XCTAssertTrue(out.hasPrefix(String(text.prefix(text.count - old.count - 3))))
        XCTAssertTrue(out.contains("command = \"not ours\""))
        XCTAssertTrue(out.hasSuffix("command = \"\(bcu)\"\nargs = [\"mcp\"]\n"))
    }

    func testByteOrderMark() throws {
        let text = "\u{FEFF}[mcp_servers.background-computer-use]\ncommand = \"\(old)\"\nargs = [\"mcp\"]\n"
        XCTAssertEqual(try set(text), text.replacingOccurrences(of: old, with: bcu))
    }

    // MARK: Reading

    func testCommandReadsEscapesAndLiteralStrings() {
        XCTAssertEqual(CodexTOML.command(in: "[mcp_servers.x]\ncommand = \"a\\\\b \\\"q\\\" \\u00e9\"\n", server: "x"), "a\\b \"q\" é")
        XCTAssertEqual(CodexTOML.command(in: "[mcp_servers.x]\ncommand = 'C:\\bin'\n", server: "x"), "C:\\bin")
        XCTAssertNil(CodexTOML.command(in: "[mcp_servers.y]\ncommand = \"z\"\n", server: "x"))
        XCTAssertNil(CodexTOML.command(in: "[mcp_servers.x]\nargs = []\n[other]\ncommand = \"z\"\n", server: "x"))
    }

    func testQuoteRoundTrips() {
        for s in ["/a b/c", "with \"quotes\"", "back\\slash", "tab\tnew\nline", "é ✓"] {
            XCTAssertEqual(CodexTOML.command(in: "[mcp_servers.x]\ncommand = \(CodexTOML.quote(s))\n", server: "x"), s)
        }
    }

    func testKeyQuotesOnlyWhenNeeded() {
        XCTAssertEqual(CodexTOML.key(["mcp_servers", "background-computer-use"]), "mcp_servers.background-computer-use")
        XCTAssertEqual(CodexTOML.key(["a b", "c.d"]), "\"a b\".\"c.d\"")
    }
}

/// Finding `claude` in what an interactive shell prints.
final class ClaudeLookupTests: XCTestCase {
    private let marker = "__BCU_PATH__="

    func testPathAmidProfileNoise() {
        let out = "Welcome back!\n/Users/me/.nvm/versions/node/v22.1.0/bin/claude\n__BCU_PATH__=/Users/me/.nvm/versions/node/v22.1.0/bin:/usr/bin:/bin\n"
        let r = AgentSetup.parseShellLookup(out, marker: marker)
        XCTAssertEqual(r.claude, "/Users/me/.nvm/versions/node/v22.1.0/bin/claude")
        XCTAssertEqual(r.path, ["/Users/me/.nvm/versions/node/v22.1.0/bin", "/usr/bin", "/bin"])
    }

    func testAlias() {
        let zsh = AgentSetup.parseShellLookup("claude='/Users/me/.claude/local/claude'\n", marker: marker)
        XCTAssertEqual(zsh.claude, "/Users/me/.claude/local/claude")
        let bash = AgentSetup.parseShellLookup("alias claude='~/.claude/local/claude --verbose'\n", marker: marker)
        XCTAssertEqual(bash.claude, "~/.claude/local/claude")
    }

    func testFishSpaceSeparatedPath() {
        let r = AgentSetup.parseShellLookup("__BCU_PATH__=/a/bin /b/bin\n", marker: marker)
        XCTAssertNil(r.claude)
        XCTAssertEqual(r.path, ["/a/bin", "/b/bin"])
    }

    func testPathWithASpaceInADirectory() {
        let r = AgentSetup.parseShellLookup("__BCU_PATH__=/Users/me/Node Versions/v22/bin:/usr/bin\n", marker: marker)
        XCTAssertEqual(r.path, ["/Users/me/Node Versions/v22/bin", "/usr/bin"])
    }

    func testNotFound() {
        let r = AgentSetup.parseShellLookup("", marker: marker)
        XCTAssertNil(r.claude)
        XCTAssertEqual(r.path, [])
    }

    func testRunTimesOut() {
        let start = Date()
        let (status, output) = AgentSetup.run("/bin/sleep", ["10"], timeout: 0.5)
        XCTAssertEqual(status, -2)
        XCTAssertTrue(output.contains("didn't finish"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunReturnsOutputWhenABackgroundChildHoldsThePipe() {
        let start = Date()
        let (status, output) = AgentSetup.run("/bin/sh", ["-c", "echo hi; sleep 10 &"], timeout: 5)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, "hi")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testTemporaryLocation() {
        XCTAssertTrue(AgentSetup.isTemporaryLocation(URL(fileURLWithPath:
            "/private/var/folders/xy/T/AppTranslocation/1234/d/Background Computer Use.app")))
        XCTAssertFalse(AgentSetup.isTemporaryLocation(URL(fileURLWithPath: NSTemporaryDirectory())))
    }
}

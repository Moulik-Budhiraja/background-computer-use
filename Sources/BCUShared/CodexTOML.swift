import Foundation

/// Just enough TOML to find and edit one MCP server in Codex's config.toml
/// while leaving every other byte of the file as it was. It reads the server
/// written as a `[mcp_servers.name]` table, with dotted keys, or as an inline
/// table, keeps CRLF line endings and comments, and only touches `command`
/// and `args`.
enum CodexTOML {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// A key set somewhere in the file, with its full path from the root.
    struct Assignment {
        var path: [String]
        /// The value's text.
        var value: Range<Int>
        /// The value, when it's a string.
        var string: String?
        /// The whole statement: a line, newline included, or an inline table entry.
        var statement: Range<Int>
        /// The table the key is written in; the key's own text is the rest of `path`.
        var table: [String]
        var inline: Bool
    }

    struct InlineTable {
        var path: [String]
        /// Offset of `{`.
        var open: Int
        var isEmpty: Bool
    }

    struct Header {
        var path: [String]
        var isArray: Bool
        /// The header's line, newline included.
        var line: Range<Int>
    }

    struct Document {
        var text: [Unicode.Scalar]
        var headers: [Header] = []
        var assignments: [Assignment] = []
        var inlineTables: [InlineTable] = []
    }

    // MARK: Reading

    static func parse(_ text: String) throws -> Document {
        var p = Parser(s: Array(text.unicodeScalars))
        try p.parseDocument()
        return p.doc
    }

    /// The server's `command`, if it's set to a string.
    static func command(in text: String, server name: String) -> String? {
        guard let doc = try? parse(text) else { return nil }
        let path = ["mcp_servers", name, "command"]
        return doc.assignments.first { $0.path == path }?.string
    }

    // MARK: Editing

    /// The file with the server's `command` and `args` set, adding the server
    /// if it isn't there. Throws when the file isn't TOML it can follow, so
    /// it's never rewritten blind.
    static func settingServer(in text: String, name: String, command: String, args: [String]) throws -> String {
        let doc = try parse(text)
        let s = doc.text
        let nl = text.contains("\r\n") ? "\r\n" : "\n"
        let server = ["mcp_servers", name]
        let commandValue = quote(command)
        let argsValue = "[" + args.map(quote).joined(separator: ", ") + "]"
        var edits: [(range: Range<Int>, text: String)] = []

        // An earlier version appended a second table when it missed the first,
        // which Codex refuses to load. Drop the extras that hold only our keys.
        let tables = doc.headers.filter { !$0.isArray && $0.path == server }
        var removed: [Range<Int>] = []
        for header in tables.dropFirst() {
            let end = doc.headers.first { $0.line.lowerBound > header.line.lowerBound }?.line.lowerBound ?? s.count
            let section = header.line.lowerBound..<end
            let keys = doc.assignments.filter { !$0.inline && section.contains($0.statement.lowerBound) }
            if keys.allSatisfy({ $0.path == server + ["command"] || $0.path == server + ["args"] }) {
                removed.append(section)
                edits.append((section, ""))
            }
        }
        let live = doc.assignments.filter { a in !removed.contains { $0.contains(a.statement.lowerBound) } }

        // Codex won't load a server with both a URL and a command. Drop the
        // HTTP keys when each is a line of its own; otherwise stop.
        let httpKeys = ["url", "bearer_token_env_var", "http_headers", "env_http_headers"]
        func isHTTP(_ path: [String]) -> Bool {
            path.count > 2 && Array(path.prefix(2)) == server && httpKeys.contains(path[2])
        }
        let httpError = ParseError(description: "\(name) is set up as an HTTP server. Remove its url and connect again.")
        if doc.headers.contains(where: { isHTTP($0.path) }) { throw httpError }
        for a in live where isHTTP(a.path) {
            guard !a.inline else { throw httpError }
            edits.append((a.statement, ""))
        }

        let existingCommand = live.first { $0.path == server + ["command"] }
        let existingArgs = live.first { $0.path == server + ["args"] }
        if let a = existingCommand { edits.append((a.value, commandValue)) }
        if let a = existingArgs { edits.append((a.value, argsValue)) }

        var missing: [(key: String, value: String)] = []
        if existingCommand == nil { missing.append(("command", commandValue)) }
        if existingArgs == nil { missing.append(("args", argsValue)) }

        if !missing.isEmpty {
            func lines(_ prefix: [String]) -> String {
                missing.map { key(prefix + [$0.key]) + " = " + $0.value + nl }.joined()
            }
            func entries(_ prefix: [String]) -> [String] {
                missing.map { key(prefix + [$0.key]) + " = " + $0.value }
            }
            /// New lines go at `at`, the end of a line, or of a file with no final newline.
            func insertLines(_ body: String, at: Int) {
                let needsBreak = at == s.count && at > 0 && s[at - 1] != "\n"
                edits.append((at..<at, (needsBreak ? nl : "") + body))
            }
            func insertEntries(_ items: [String], intoInlineAt open: Int, isEmpty: Bool) {
                edits.append((open + 1..<open + 1, " " + items.joined(separator: ", ") + (isEmpty ? " " : ",")))
            }

            /// Written in a table above the server's, so new keys can go
            /// next to it. Not one under it, like `[mcp_servers.<name>.env]`.
            func aboveServer(_ a: Assignment) -> Bool {
                a.table.count < server.count && Array(server.prefix(a.table.count)) == a.table
            }

            let after = existingCommand ?? existingArgs
            if let a = after, !a.inline {
                // Next to the key that's there, written the same way.
                insertLines(lines(Array(a.path.dropFirst(a.table.count).dropLast())), at: a.statement.upperBound)
            } else if let a = after {
                let items = entries(Array(a.path.dropFirst(a.table.count).dropLast()))
                edits.append((a.statement.upperBound..<a.statement.upperBound, ", " + items.joined(separator: ", ")))
            } else if let header = tables.first {
                insertLines(lines([]), at: header.line.upperBound)
            } else if let t = doc.inlineTables.first(where: { $0.path == server }) {
                insertEntries(entries([]), intoInlineAt: t.open, isEmpty: t.isEmpty)
            } else if let a = live.last(where: { !$0.inline && $0.path.count > 2 && Array($0.path.prefix(2)) == server && aboveServer($0) }) {
                // Dotted keys like `background-computer-use.env.X = 1` in [mcp_servers].
                insertLines(lines(Array(server.dropFirst(a.table.count))), at: a.statement.upperBound)
            } else if let a = live.last(where: { $0.inline && $0.path.count > 2 && Array($0.path.prefix(2)) == server && aboveServer($0) }) {
                let items = entries(Array(server.dropFirst(a.table.count)))
                edits.append((a.statement.upperBound..<a.statement.upperBound, ", " + items.joined(separator: ", ")))
            } else if let t = doc.inlineTables.first(where: { $0.path == ["mcp_servers"] }) {
                // `mcp_servers = { ... }` is closed, so a table header can't add to it.
                let table = "{ " + entries([]).joined(separator: ", ") + " }"
                insertEntries([key([name]) + " = " + table], intoInlineAt: t.open, isEmpty: t.isEmpty)
            } else if doc.assignments.contains(where: { $0.path == ["mcp_servers"] || $0.path == server }) {
                throw ParseError(description: "mcp_servers isn't a table.")
            } else {
                // A new table at the end, after a blank line.
                var end = s.count
                while end > 0, [" ", "\t", "\r", "\n"].contains(s[end - 1]) { end -= 1 }
                let table = "[" + key(server) + "]" + nl + lines([])
                edits.append((end..<s.count, end == 0 ? table : nl + nl + table))
            }
        }

        // Last first, so earlier offsets still hold; a removal before an
        // insertion at the same place.
        var out = s
        for e in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound) }) {
            out.replaceSubrange(e.range, with: Array(e.text.unicodeScalars))
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: out)
        return String(result)
    }

    // MARK: Writing values

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 || c.value == 0x7F { out += String(format: "\\u%04X", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    /// A dotted key, each part bare when it can be.
    static func key(_ parts: [String]) -> String {
        parts.map { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(Parser.isBare) ? part : quote(part)
        }.joined(separator: ".")
    }

    // MARK: Parser

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var doc: Document

        init(s: [Unicode.Scalar]) {
            self.s = s
            doc = Document(text: s)
        }

        static func isBare(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        func peek(_ n: Int = 0) -> Unicode.Scalar? { i + n < s.count ? s[i + n] : nil }

        func fail(_ what: String) -> ParseError {
            let line = s[..<min(i, s.count)].filter { $0 == "\n" }.count + 1
            return ParseError(description: "\(what) on line \(line).")
        }

        mutating func skipSpaces() { while let c = peek(), c == " " || c == "\t" { i += 1 } }

        /// Spaces, newlines and comments, as allowed inside arrays.
        mutating func skipBlank() {
            while let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
                else if c == "#" { skipComment() }
                else { break }
            }
        }

        mutating func skipComment() { while let c = peek(), c != "\n" { i += 1 } }

        mutating func expect(_ c: Unicode.Scalar) throws {
            guard peek() == c else { throw fail("Expected \(c)") }
            i += 1
        }

        /// What can follow a statement: spaces, a comment, then a newline or the end.
        mutating func endOfStatement() throws {
            skipSpaces()
            if peek() == "#" { skipComment() }
            if peek() == "\r", peek(1) == "\n" { i += 2 }
            else if peek() == "\n" { i += 1 }
            else if peek() != nil { throw fail("Unexpected text") }
        }

        mutating func parseDocument() throws {
            if peek() == "\u{FEFF}" { i += 1 }
            var table: [String] = []
            var inArrayTable = false
            while let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
                if c == "#" { skipComment(); continue }
                var lineStart = i
                while lineStart > 0, s[lineStart - 1] != "\n" { lineStart -= 1 }
                if c == "[" {
                    let isArray = peek(1) == "["
                    i += isArray ? 2 : 1
                    skipSpaces()
                    let path = try parseKey()
                    skipSpaces()
                    try expect("]")
                    if isArray { try expect("]") }
                    try endOfStatement()
                    doc.headers.append(Header(path: path, isArray: isArray, line: lineStart..<i))
                    table = path
                    inArrayTable = isArray
                    continue
                }
                let keyPath = try parseKey()
                skipSpaces()
                try expect("=")
                skipSpaces()
                // Keys under [[array tables]] belong to one element; nothing here edits those.
                let (value, string) = try parseValue(path: table + keyPath, record: !inArrayTable)
                try endOfStatement()
                if !inArrayTable {
                    doc.assignments.append(Assignment(path: table + keyPath, value: value, string: string,
                                                      statement: lineStart..<i, table: table, inline: false))
                }
            }
        }

        mutating func parseKey() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                switch peek() {
                case "\"": parts.append(try parseBasicString())
                case "'": parts.append(try parseLiteralString())
                default:
                    let start = i
                    while let c = peek(), Self.isBare(c) { i += 1 }
                    guard i > start else { throw fail("Expected a key") }
                    parts.append(Self.string(s[start..<i]))
                }
                skipSpaces()
                guard peek() == "." else { return parts }
                i += 1
            }
        }

        /// Parses a value, recording the keys of any inline table in it.
        mutating func parseValue(path: [String], record: Bool) throws -> (Range<Int>, String?) {
            let start = i
            var string: String?
            switch peek() {
            case "\"":
                string = peek(1) == "\"" && peek(2) == "\"" ? try parseMultilineBasicString() : try parseBasicString()
            case "'":
                string = peek(1) == "'" && peek(2) == "'" ? try parseMultilineLiteralString() : try parseLiteralString()
            case "[":
                i += 1
                while true {
                    skipBlank()
                    if peek() == "]" { i += 1; break }
                    _ = try parseValue(path: [], record: false)
                    skipBlank()
                    if peek() == "," { i += 1; continue }
                    try expect("]")
                    break
                }
            case "{":
                let open = i
                i += 1
                skipBlank()
                var isEmpty = true
                while peek() != "}" {
                    isEmpty = false
                    let entryStart = i
                    let keyPath = try parseKey()
                    skipSpaces()
                    try expect("=")
                    skipSpaces()
                    let (value, str) = try parseValue(path: path + keyPath, record: record)
                    if record {
                        doc.assignments.append(Assignment(path: path + keyPath, value: value, string: str,
                                                          statement: entryStart..<value.upperBound, table: path, inline: true))
                    }
                    skipBlank()
                    if peek() == "," { i += 1; skipBlank(); continue }
                    guard peek() == "}" else { throw fail("Expected } or ,") }
                }
                i += 1
                if record { doc.inlineTables.append(InlineTable(path: path, open: open, isEmpty: isEmpty)) }
            default:
                // A number, boolean or date. A date and time can be split by a space.
                func scan(_ p: inout Parser) {
                    while let c = p.peek(), !" \t\r\n,]}#".unicodeScalars.contains(c) { p.i += 1 }
                }
                scan(&self)
                if i - start == 10, peek() == " ", let d = peek(1), ("0"..."9").contains(d),
                   Self.string(s[start..<i]).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                    i += 1
                    scan(&self)
                }
                guard i > start else { throw fail("Expected a value") }
            }
            return (start..<i, string)
        }

        mutating func parseBasicString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek(), c != "\n" else { throw fail("Unterminated string") }
                i += 1
                if c == "\"" { return String(out) }
                if c == "\\" { out.append(contentsOf: try parseEscape()) } else { out.append(c) }
            }
        }

        mutating func parseMultilineBasicString() throws -> String {
            i += 3
            if peek() == "\r", peek(1) == "\n" { i += 2 } else if peek() == "\n" { i += 1 }
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek() else { throw fail("Unterminated string") }
                if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    i += 3
                    // Up to two more quotes belong to the string.
                    while peek() == "\"" { out.append("\""); i += 1 }
                    return String(out)
                }
                i += 1
                guard c == "\\" else { out.append(c); continue }
                // A backslash at the end of a line trims the break and the indent after it.
                var j = i
                while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                if j < s.count, s[j] == "\n" || s[j] == "\r" {
                    i = j
                    while let w = peek(), " \t\r\n".unicodeScalars.contains(w) { i += 1 }
                } else {
                    out.append(contentsOf: try parseEscape())
                }
            }
        }

        mutating func parseLiteralString() throws -> String {
            try expect("'")
            let start = i
            while let c = peek(), c != "'" {
                guard c != "\n" else { throw fail("Unterminated string") }
                i += 1
            }
            guard peek() == "'" else { throw fail("Unterminated string") }
            let out = Self.string(s[start..<i])
            i += 1
            return out
        }

        mutating func parseMultilineLiteralString() throws -> String {
            i += 3
            if peek() == "\r", peek(1) == "\n" { i += 2 } else if peek() == "\n" { i += 1 }
            let start = i
            while i < s.count {
                if s[i] == "'", peek(1) == "'", peek(2) == "'" {
                    var end = i + 3
                    while end < s.count, s[end] == "'" { end += 1 }
                    let out = Self.string(s[start..<end - 3])
                    i = end
                    return out
                }
                i += 1
            }
            throw fail("Unterminated string")
        }

        /// After a backslash.
        mutating func parseEscape() throws -> [Unicode.Scalar] {
            guard let c = peek() else { throw fail("Unterminated string") }
            i += 1
            switch c {
            case "b": return ["\u{08}"]
            case "t": return ["\t"]
            case "n": return ["\n"]
            case "f": return ["\u{0C}"]
            case "r": return ["\r"]
            case "e": return ["\u{1B}"]
            case "\"": return ["\""]
            case "\\": return ["\\"]
            case "u", "U", "x":
                let n = c == "u" ? 4 : c == "U" ? 8 : 2
                guard i + n <= s.count, let v = UInt32(Self.string(s[i..<i + n]), radix: 16),
                      let scalar = Unicode.Scalar(v) else { throw fail("Bad escape") }
                i += n
                return [scalar]
            default: throw fail("Bad escape")
            }
        }

        static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars)
            return String(v)
        }
    }
}

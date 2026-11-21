import AppKit
import BCUCore
import BCUShared

// Started as the front gate's watchdog (by `bcu serve`): that's all this process does.
FrontGate.runWatchdogIfAsked()

// bcu: command-line front end for Background Computer Use.
//   bcu mcp                      stdio MCP server (what agents run)
//   bcu serve                    the engine without the menu bar app (for host apps)
//   bcu call <tool> ['<json>']   call one tool and print the result
//   bcu status                   same as `bcu call status`
//   bcu docs                     everything an agent is told, as Markdown
//   bcu install-skill            copy the skill into Claude Code and Codex
//   bcu --version                print the version

let usage = """
usage:
  bcu mcp [--host ID] [--session ID] [--label NAME]
                                run the MCP server on stdin/stdout. A host app passes
                                --host so it shows the session in its own UI, and can
                                name the session and its label
  bcu serve [--owner NAME] [--log-dir DIR] [--no-parent-watch] [--own-engine]
            [--trust-client TEAM_ID|PATH]...
                                run the engine without the menu bar app, for a host
                                app (see docs/embedding.md); it stops when its parent does.
                                If the app is installed and set up, starts it and uses
                                its engine instead, unless --own-engine. --trust-client
                                lets in a client the code signature check would refuse
  bcu call <tool> ['{json}']    call one tool (images are saved, readable only by you, under $TMPDIR/bcu)
  bcu status                    show the app's status
  bcu tools                     list tool names
  bcu docs                      print everything an agent is told (instructions, tools, skill) as Markdown
  bcu install-skill             install the skill for Claude Code (~/.claude/skills) and Codex (~/.codex/skills)
  bcu --version                 print this bcu's version
"""

/// The app this `bcu` was shipped inside, if it isn't this one: a host app
/// that runs the engine itself (`bcu serve`).
let hostApp: Bundle? = {
    let b = BCUCopy.app(containing: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())
    return b?.bundleIdentifier == BCUPaths.bundleID ? nil : b
}()

/// Who to open when the engine isn't running.
var ownerName: String {
    (hostApp?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? BCUPaths.appName
}

/// Why there's no engine to talk to, in words an agent can pass on.
enum ConnectError: Error, CustomStringConvertible {
    case notInstalled
    case launchFailed(String)
    case didNotStart(String)

    var description: String {
        switch self {
        case .notInstalled:
            return "\(BCUPaths.appName) isn't installed on this Mac. Ask the user to install it and open it once to set it up."
        case .launchFailed(let why):
            return "\(BCUPaths.appName) is installed but couldn't be opened (\(why)). Ask the user to open it."
        case .didNotStart(let owner):
            return "\(owner) isn't running: it didn't answer within 15 seconds. Ask the user to open \(owner)."
        }
    }
}

/// Connect to the engine. Launches this app in the background if it isn't
/// running; inside a host app, waits for the host to start its engine.
/// Fails at once when there's no app to launch.
func connect() throws -> SocketClient {
    if let client = try? SocketClient() { return client }
    if hostApp == nil { try launchApp() }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if let client = try? SocketClient() { return client }
        usleep(200_000)
    }
    throw ConnectError.didNotStart(ownerName)
}

/// Where the app is: around this `bcu`, else wherever LaunchServices or the
/// app's own note of itself says.
func appLocation() -> URL? {
    // bcu lives at <App>.app/Contents/MacOS/bcu.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let around = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if around.pathExtension == "app" { return around }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BCUPaths.bundleID) { return url }
    if let path = AppRecord.read()?.path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    return nil
}

func launchApp() throws {
    guard let url = appLocation() else { throw ConnectError.notInstalled }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        failure = error
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 10)
    if let failure { throw ConnectError.launchFailed(failure.localizedDescription) }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// A folder only this user can read, for the images `bcu call` saves.
let imageDirectory: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcu", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(dir.path, 0o700)
    return dir
}()

func printResult(_ result: ToolResult) {
    if result.isError { printError(result.text) } else { print(result.text) }
    let stamp = Int(Date().timeIntervalSince1970)
    for (i, image) in result.images.enumerated() {
        guard let data = Data(base64Encoded: image.base64) else { continue }
        let path = imageDirectory.appendingPathComponent("bcu-\(stamp)-\(UUID().uuidString.prefix(8))-\(i).png").path
        // Readable by this user only, and never an existing file.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { printError("bcu: couldn't save an image to \(path)"); continue }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
        close(fd)
        if ok { print("[image saved to \(path)]") } else { printError("bcu: couldn't save an image to \(path)") }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    printError(usage)
    exit(1)
}

switch command {
case "mcp":
    var host: String?, session: String?, label: String?
    var i = 1
    while i < args.count {
        let value = i + 1 < args.count ? args[i + 1] : nil
        switch args[i] {
        case "--host": host = value
        case "--session": session = value
        case "--label": label = value
        default:
            FileHandle.standardError.write(Data("bcu: unknown option \(args[i])\n".utf8))
            exit(64)
        }
        i += 2
    }
    MCPServer(host: host, session: session, label: label).run()
case "serve":
    Serve.run(Array(args.dropFirst()))
case "call":
    guard args.count >= 2 else { printError(usage); exit(1) }
    var toolArgs: JSONObject = [:]
    if args.count >= 3 {
        guard let data = args[2].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            printError("bcu: arguments must be a JSON object")
            exit(1)
        }
        toolArgs = obj
    }
    do {
        let result = try connect().call(tool: args[1], args: toolArgs)
        printResult(result)
        exit(result.isError ? 2 : 0)
    } catch {
        printError("bcu: \(error)")
        exit(1)
    }
case "status":
    do {
        printResult(try connect().call(tool: "status", args: [:]))
    } catch {
        printError("bcu: \(error)")
        exit(1)
    }
case "tools":
    for t in ToolCatalog.tools { print(t["name"] as? String ?? "") }
case "docs":
    print(AgentDocs.markdown(skill: AgentDocs.skillFile()))
case "install-skill":
    do {
        for path in try AgentDocs.installSkill() { print("installed \(path)") }
    } catch {
        printError("bcu: \(error)")
        exit(1)
    }
case "--version", "version":
    print(BCUVersion.current)
default:
    printError(usage)
    exit(1)
}

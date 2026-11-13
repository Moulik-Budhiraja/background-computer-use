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

let usage = """
usage:
  bcu mcp [--host ID] [--session ID] [--label NAME]
                                run the MCP server on stdin/stdout. A host app passes
                                --host so it shows the session in its own UI, and can
                                name the session and its label
  bcu serve [--owner NAME] [--log-dir DIR] [--no-parent-watch] [--own-engine]
                                run the engine without the menu bar app, for a host
                                app (see docs/embedding.md); it stops when its parent does.
                                If the app is installed and set up, starts it and uses
                                its engine instead, unless --own-engine
  bcu call <tool> ['{json}']    call one tool (images are saved to /tmp/bcu-*.png)
  bcu status                    show the app's status
  bcu tools                     list tool names
  bcu docs                      print everything an agent is told (instructions, tools, skill) as Markdown
  bcu install-skill             install the skill for Claude Code (~/.claude/skills) and Codex (~/.codex/skills)
"""

/// The app this `bcu` was shipped inside, if it isn't this one: a host app
/// that runs the engine itself (`bcu serve`).
let hostApp: Bundle? = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    while dir.path != "/" {
        if dir.pathExtension == "app" {
            let b = Bundle(url: dir)
            return b?.bundleIdentifier == BCUPaths.bundleID ? nil : b
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}()

/// Who to open when the engine isn't running.
var ownerName: String {
    (hostApp?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? BCUPaths.appName
}

/// Connect to the engine. Launches this app in the background if it isn't
/// running; inside a host app, waits for the host to start its engine.
func connect() throws -> SocketClient {
    if let client = try? SocketClient() { return client }
    if hostApp == nil { launchApp() }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if let client = try? SocketClient() { return client }
        usleep(200_000)
    }
    throw SocketError.notRunning
}

func launchApp() {
    // bcu lives at <App>.app/Contents/MacOS/bcu; fall back to LaunchServices lookup.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var appURL: URL? = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if appURL?.pathExtension != "app" {
        appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BCUPaths.bundleID)
    }
    guard let url = appURL else {
        FileHandle.standardError.write(Data("bcu: can't find \(BCUPaths.appName).app\n".utf8))
        return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 10)
}

func printResult(_ result: ToolResult) {
    print(result.text)
    for (i, image) in result.images.enumerated() {
        guard let data = Data(base64Encoded: image.base64) else { continue }
        let path = "/tmp/bcu-\(Int(Date().timeIntervalSince1970))-\(i).png"
        try? data.write(to: URL(fileURLWithPath: path))
        print("[image saved to \(path)]")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
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
    guard args.count >= 2 else { print(usage); exit(1) }
    var toolArgs: JSONObject = [:]
    if args.count >= 3 {
        guard let data = args[2].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            print("bcu: arguments must be a JSON object")
            exit(1)
        }
        toolArgs = obj
    }
    do {
        let result = try connect().call(tool: args[1], args: toolArgs)
        printResult(result)
        exit(result.isError ? 2 : 0)
    } catch {
        print("bcu: \(error)")
        exit(1)
    }
case "status":
    do {
        printResult(try connect().call(tool: "status", args: [:]))
    } catch {
        print("bcu: \(error)")
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
        print("bcu: \(error)")
        exit(1)
    }
default:
    print(usage)
    exit(1)
}

import AppKit
import BCUShared

// bcu: command-line front end for Background Computer Use.
//   bcu mcp                      stdio MCP server (what agents run)
//   bcu call <tool> ['<json>']   call one tool and print the result
//   bcu status                   same as `bcu call status`

let usage = """
usage:
  bcu mcp                       run the MCP server on stdin/stdout
  bcu call <tool> ['{json}']    call one tool (images are saved to /tmp/bcu-*.png)
  bcu status                    show the app's status
  bcu tools                     list tool names
"""

/// Connect to the app, launching it in the background if it isn't running.
func connect() throws -> SocketClient {
    if let client = try? SocketClient() { return client }
    launchApp()
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
    MCPServer().run()
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
default:
    print(usage)
    exit(1)
}

import AppKit

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--history-selftest"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    HistorySelfTest.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
if let i = CommandLine.arguments.firstIndex(of: "--history-render"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    HistorySelfTest.render(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// `kill` / `pkill` send SIGTERM; route it through terminate so windows are
// released and the display removed cleanly.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApp.terminate(nil) }
termSource.resume()

app.run()

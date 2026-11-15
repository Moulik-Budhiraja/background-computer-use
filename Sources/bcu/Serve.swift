import AppKit
import BCUCore
import BCUShared

/// `bcu serve`: the engine without the menu bar app, for a host app that
/// shows agents' screens in its own UI (see docs/embedding.md). The host
/// starts it as a child process, so macOS counts its Accessibility and
/// Screen Recording permissions as the host's.
///
/// One engine runs per Mac. The first line on stdout says which:
///   {"event":"ready", ...}    this process is the engine
///   {"event":"running", ...}  another one is (this app, or another host's);
///                             this process exits and the host uses that one
/// Either way, the engine is at `socket`.
///
/// When this app is installed and has its permissions (`AppRecord`), it
/// starts the app and uses its engine instead, unless `--own-engine`.
enum Serve {
    static func run(_ args: [String]) -> Never {
        var owner = "Background Computer Use engine"
        var watchParent = true
        var ownEngine = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--owner" where i + 1 < args.count:
                owner = args[i + 1]; i += 1
            case "--log-dir" where i + 1 < args.count:
                BCUPaths.logDirectoryOverride = URL(fileURLWithPath: args[i + 1], isDirectory: true); i += 1
            case "--no-parent-watch":
                watchParent = false
            case "--own-engine":
                ownEngine = true
            default:
                emit(["event": "error", "error": "unknown option \(args[i])"])
                exit(64)
            }
            i += 1
        }

        func running() -> Never {
            let current = EngineLock.current()
            var o: JSONObject = ["event": "running", "socket": BCUPaths.socketPath,
                                 "owner": current?.name ?? BCUPaths.appName]
            if let current { o["pid"] = Int(current.pid); o["version"] = current.version }
            emit(o)
            exit(0)
        }

        if !ownEngine, !engineRunning, let record = AppRecord.read(), record.isUsable {
            if startApp(record) { running() }
            Log.info("\(BCUPaths.appName) didn't start its engine; running one for \(owner)")
        }

        guard let lock = EngineLock.acquire(name: owner, version: BCUVersion.current) else { running() }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CrashLog.install()
        let hub = Hub()
        hub.start()
        let host = HostServer(hub: hub, ownerName: owner, version: BCUVersion.current)
        let server = SocketServer { tool, args in hub.call(tool: tool, args: args) }
        server.hostHandler = { op, req, connection in host.handle(op, req, connection) }
        server.sessionHandler = { [hub] session, on in hub.sessionAttached(session, on) }
        do {
            try server.start()
        } catch {
            emit(["event": "error", "error": "\(error)"])
            exit(1)
        }
        Log.info("engine started for \(owner), version \(BCUVersion.current)")

        var stopping = false
        func shutdown(_ why: String) {
            guard !stopping else { return }
            stopping = true
            Log.info("engine stopping: \(why)")
            server.stop()
            hub.shutdown()
            exit(0)
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        var sources: [DispatchSourceProtocol] = []
        for sig in [SIGTERM, SIGINT] {
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { shutdown("signal \(sig)") }
            s.resume()
            sources.append(s)
        }
        // The host quit or crashed: its agents went with it.
        let parent = getppid()
        if watchParent && parent > 1 {
            let s = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
            s.setEventHandler { shutdown("the app that started it quit") }
            s.resume()
            sources.append(s)
        }

        // The menu bar app asked for the engine back: hand it over once no agent is working.
        var yielding = false
        host.onYield = {
            if !yielding { Log.info("asked to yield; stopping once no agent is working") }
            yielding = true
        }
        // The event tap needs Accessibility; install it as soon as it's granted.
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if AX.isTrusted && !hub.focusGuard.tapInstalled { hub.focusGuard.installTap() }
            if yielding && hub.activeEngines.isEmpty && !hub.isActive { shutdown("yielded to \(BCUPaths.appName)") }
        }

        emit(["event": "ready", "socket": BCUPaths.socketPath, "pid": Int(getpid()), "version": BCUVersion.current,
              "protocol": HostServer.protocolVersion])
        withExtendedLifetime((lock, sources, timer, host)) { app.run() }
        exit(0)
    }

    /// An engine holds the lock, or one from before the lock serves the socket.
    static var engineRunning: Bool {
        EngineLock.current() != nil || (try? SocketClient()) != nil
    }

    /// Start the menu bar app, in the background, and wait for its engine.
    static func startApp(_ record: AppRecord) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        if let home = ProcessInfo.processInfo.environment["BCU_HOME"] { config.environment = ["BCU_HOME": home] }
        let opened = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: record.path), configuration: config) { _, error in
            failure = error
            opened.signal()
        }
        guard opened.wait(timeout: .now() + 10) == .success, failure == nil else {
            Log.info("couldn't open \(record.path): \(failure.map { "\($0)" } ?? "timed out")")
            return false
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if EngineLock.current() != nil, (try? SocketClient()) != nil { return true }
            usleep(100_000)
        }
        return false
    }

    static func emit(_ o: JSONObject) {
        FileHandle.standardOutput.write(WireCodec.encodeLine(o))
    }
}

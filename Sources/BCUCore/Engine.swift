import AppKit
import BCUShared
import CPrivate

public enum EngineStatus: Equatable {
    case idle
    case working(String)
    case waiting(String)
    case paused
}

public struct ActivityItem {
    public let time: Date
    public let text: String
    public let isError: Bool
}

/// Runs tool calls one at a time on its own queue and publishes state for the menu bar.
public final class Engine {
    public let display: AgentDisplay
    public let focusGuard: FocusGuard
    public let windows: WindowManager

    /// Called on the main thread whenever status, activity or windows change.
    public var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "bcu.engine")
    private let stateLock = NSLock()
    private var snapshots: [CGWindowID: AXSnapshotResult] = [:]
    private var enhancedPids: Set<pid_t> = []
    private var _activity: [ActivityItem] = []
    private var _paused = false
    private var _waitingReason: String?
    private var _busy: String?
    private var lastCallMs = 0.0

    public init(width: Int = 1600, height: Int = 1000) {
        display = AgentDisplay(width: width, height: height)
        focusGuard = FocusGuard(display: display)
        windows = WindowManager(display: display, focusGuard: focusGuard)
        focusGuard.onEvent = { [weak self] _ in self?.changed() }
    }

    /// Main thread.
    public func start() throws {
        try display.start()
        let recovered = windows.recoverFromPreviousRun()
        if !recovered.isEmpty { log("Cleaned up after the last run: " + recovered.joined(separator: "; ")) }
        focusGuard.start()
        windows.startWatchdog()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.changed() }
    }

    /// Main thread. Releases windows (closing opened, returning borrowed) before
    /// the display goes away, so nothing lands on the user's screen.
    public func shutdown() {
        var done = false
        queue.async {
            _ = self.windows.releaseAll()
            DispatchQueue.main.async { done = true }
        }
        let deadline = Date().addingTimeInterval(4)
        while !done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        display.stop()
    }

    // MARK: State for the UI

    public var paused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _paused
    }

    public func setPaused(_ value: Bool) {
        stateLock.lock(); _paused = value; stateLock.unlock()
        log(value ? "Paused by you" : "Resumed")
    }

    public var status: EngineStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        if _paused { return .paused }
        if let r = _waitingReason { return .waiting(r) }
        if let handoff = windows.windows.first(where: { $0.handedOff }) {
            return .waiting(handoff.handoffReason ?? "\(handoff.appName) needs you")
        }
        if let b = _busy { return .working(b) }
        if nowMs() - lastCallMs < 8000 || !windows.windows.isEmpty {
            let apps = Set(windows.windows.map(\.appName)).sorted()
            return .working(apps.isEmpty ? "Working" : "Working in \(apps.joined(separator: ", "))")
        }
        return .idle
    }

    /// True while a tool call runs and for a short debounce after, so the menu
    /// bar icon doesn't flicker between an agent's calls.
    public var isActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _busy != nil || nowMs() - lastCallMs < 3000
    }

    public var activity: [ActivityItem] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _activity
    }

    private func log(_ text: String, error: Bool = false) {
        stateLock.lock()
        _activity.append(ActivityItem(time: Date(), text: text, isError: error))
        if _activity.count > 60 { _activity.removeFirst(_activity.count - 60) }
        stateLock.unlock()
        Log.info((error ? "error: " : "") + text)
        changed()
    }

    private func changed() {
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Stop: release every window and clear waiting state.
    public func stopAll() {
        queue.async {
            let results = self.windows.releaseAll()
            self.snapshots.removeAll()
            self.log("Stopped by you: " + (results.isEmpty ? "no windows open" : results.joined(separator: "; ")))
        }
    }

    /// The user takes over: move the agent's front window onto their screen and pause.
    public func takeOver() {
        queue.async {
            if let w = self.windows.windows.first(where: { !$0.handedOff }) {
                try? self.windows.handoff(w.id, reason: "You took over this window")
            }
            self.setPaused(true)
        }
    }

    /// The user is done: move handed-off windows back to the agent display and resume.
    public func handBack() {
        queue.async {
            for w in self.windows.windows where w.handedOff {
                try? self.windows.takeBack(w.id)
            }
            self.setPaused(false)
        }
    }

    // MARK: Dispatch

    /// Called from socket threads. Blocks until the tool finishes.
    public func call(tool: String, args: JSONObject) -> ToolResult {
        queue.sync {
            stateLock.lock()
            lastCallMs = nowMs()
            _busy = Self.describe(tool)
            stateLock.unlock()
            changed()
            defer {
                stateLock.lock()
                _busy = nil
                _waitingReason = nil
                lastCallMs = nowMs()
                stateLock.unlock()
                changed()
            }
            let readOnly: Set<String> = ["status", "guard_report", "list_apps", "list_windows", "release_window", "screenshot", "get_window_state"]
            if paused && !readOnly.contains(tool) {
                return .error("Paused by the user from the menu bar. Wait and retry later, or tell the user you're blocked.")
            }
            let monitored = !readOnly.contains(tool) || tool == "get_window_state"
            if monitored { focusGuard.startMonitor() }
            do {
                var result = try run(tool: tool, args: Args(args))
                if monitored, let focusNote = focusGuard.stopMonitor() {
                    focusGuard.record("\(tool): \(focusNote)")
                    result.text += "\n[focus guard] \(focusNote)"
                }
                if tool != "status" && tool != "guard_report" {
                    log("\(tool): \(result.text.split(separator: "\n").first.map(String.init) ?? "")")
                }
                return result
            } catch {
                if monitored { _ = focusGuard.stopMonitor(tailMs: 0) }
                log("\(tool) failed: \(error)", error: true)
                return .error("\(error)")
            }
        }
    }

    private static func describe(_ tool: String) -> String {
        switch tool {
        case "open_window": return "Opening a window"
        case "get_window_state", "screenshot": return "Looking"
        case "click", "perform_action": return "Clicking"
        case "type_text", "set_value": return "Typing"
        case "press_key": return "Pressing keys"
        case "scroll": return "Scrolling"
        default: return "Working"
        }
    }

    private func run(tool: String, args: Args) throws -> ToolResult {
        switch tool {
        case "status": return status(args)
        case "list_apps": return listApps()
        case "open_window": return try openWindow(args)
        case "list_windows": return try listWindows(args)
        case "borrow_window": return try borrowWindow(args)
        case "release_window": return try releaseWindow(args)
        case "get_window_state": return try getWindowState(args)
        case "screenshot": return try screenshot(args)
        case "click": return try click(args)
        case "set_value": return try setValue(args)
        case "perform_action": return try performAction(args)
        case "type_text": return try typeText(args)
        case "press_key": return try pressKey(args)
        case "scroll": return try scroll(args)
        case "drag": return try drag(args)
        case "press_menu_item": return try pressMenuItem(args)
        case "handoff": return try handoff(args)
        case "take_back": return try takeBack(args)
        case "guard_report": return guardReport()
        // Maintenance, not in the agent tool catalog.
        case "admin_close_window":
            return ToolResult(text: windows.closeAny(CGWindowID(try args.requireInt("window_id"))) ? "closed" : "failed")
        case "admin_move_to_user":
            var frame: CGRect?
            if let x = args.double("x"), let y = args.double("y"), let w = args.double("w"), let h = args.double("h") { frame = CGRect(x: x, y: y, width: w, height: h) }
            return ToolResult(text: windows.moveToUser(CGWindowID(try args.requireInt("window_id")), frame: frame) ? "moved" : "failed")
        case "admin_type_hid":
            return TestHarness.shared.startTyping(try args.requireString("text"), intervalMs: args.double("interval_ms") ?? 35)
        case "admin_key_hid":
            let (code, _) = try KeyMap.code(for: try args.requireString("key"))
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) {
                    e.flags = []
                    e.post(tap: .cghidEventTap)
                }
            }
            return ToolResult(text: "pressed")
        case "admin_type_status":
            return TestHarness.shared.typingStatus()
        case "admin_read_text":
            return try TestHarness.read(app: try args.requireString("app"), windows: windows)
        default: throw ToolError("unknown tool \(tool)")
        }
    }

    // MARK: Helpers

    private func agentWindow(_ args: Args) throws -> (AgentWindow, AXUIElement) {
        let id = CGWindowID(try args.requireInt("window_id"))
        guard let w = windows.window(id) else {
            throw ToolError("window \(id) isn't one of yours. Use open_window or borrow_window first, or list_windows.")
        }
        guard let ax = AX.window(pid: w.pid, id: id) else {
            windows.unregister(id)
            throw ToolError("window \(id) no longer exists")
        }
        if w.handedOff {
            throw ToolError("window \(id) is handed off to the user. Wait for them, then call take_back.")
        }
        return (w, ax)
    }

    private func node(_ args: Args, window: AgentWindow) throws -> AXNode {
        let index = try args.requireInt("element")
        guard let snap = snapshots[window.id] else {
            throw ToolError("no element numbers for window \(window.id) yet: call get_window_state first")
        }
        guard let n = snap.nodes[index] else {
            throw ToolError("element \(index) isn't in the last get_window_state for window \(window.id)")
        }
        return n
    }

    private func pngImage(_ image: CGImage) -> ToolImage? {
        guard let data = Capture.png(image) else { return nil }
        return ToolImage(mime: "image/png", base64: data.base64EncodedString())
    }

    /// Keystrokes and pixel clicks change the app's key window. If the user is
    /// in that same app, wait until they leave it.
    private func waitForTurn(_ w: AgentWindow) throws {
        try waitForTurn(pid: w.pid, appName: w.appName)
    }

    private func waitForTurn(pid: pid_t, appName: String) throws {
        func userIsIn() -> Bool {
            let front = BCUFrontProcessPID()
            return front == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        guard userIsIn() else { return }
        stateLock.lock(); _waitingReason = "Waiting for you to leave \(appName)"; stateLock.unlock()
        changed()
        defer {
            stateLock.lock(); _waitingReason = nil; stateLock.unlock()
            changed()
        }
        let deadline = nowMs() + 120_000
        while userIsIn() {
            if paused { throw ToolError("paused by the user") }
            if nowMs() > deadline {
                throw ToolError("the user has been using \(appName) for 2 minutes, so keyboard steps can't run without disturbing them. Use set_value / element clicks, or retry later.")
            }
            sleepMs(150)
        }
        sleepMs(150)
    }

    /// Run `body` with the window as its app's key window, under the guard.
    private func keyed<T>(_ w: AgentWindow, cause: String, _ body: () throws -> T) throws -> T {
        try waitForTurn(w)
        focusGuard.beginAction(pid: w.pid, cause: cause)
        windows.noteBefore(pid: w.pid)
        defer { focusGuard.endAction(pid: w.pid) }
        let scope = try KeyScope.enter(pid: w.pid, window: w.id)
        defer { scope.exit() }
        return try body()
    }

    private func guarded<T>(_ w: AgentWindow, cause: String, _ body: () throws -> T) rethrows -> T {
        focusGuard.beginAction(pid: w.pid, cause: cause)
        windows.noteBefore(pid: w.pid)
        defer { focusGuard.endAction(pid: w.pid) }
        return try body()
    }

    private func globalPoint(_ args: Args, window ax: AXUIElement) throws -> CGPoint {
        guard let x = args.double("x"), let y = args.double("y") else { throw ToolError("give an element or x and y") }
        guard let f = AX.frame(ax) else { throw ToolError("can't read the window frame") }
        return CGPoint(x: f.minX + x, y: f.minY + y)
    }

    public static func defaultBrowser() -> (name: String, bundleID: String)? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, bundle.bundleIdentifier ?? "")
    }

    // MARK: Tools

    private func status(_ args: Args) -> ToolResult {
        var lines: [String] = []
        lines.append("Agent display: \(display.width)x\(display.height) points" + (display.isRunning ? "" : " (NOT RUNNING)"))
        if let b = Self.defaultBrowser() {
            lines.append("User's default browser: \(b.name) (\(b.bundleID)). Use it when a task needs a browser.")
        }
        lines.append("Permissions: accessibility \(AX.isTrusted ? "granted" : "MISSING"), screen recording \(Capture.hasPermission ? "granted" : "MISSING")")
        if paused { lines.append("Paused by the user.") }
        let ws = windows.windows
        if ws.isEmpty {
            lines.append("You have no windows open.")
        } else {
            lines.append("Your windows:")
            for w in ws { lines.append("  \(w.id): \(w.appName) [\(w.kind.rawValue)\(w.handedOff ? ", handed off" : "")] \"\(WindowList.info(w.id)?.title ?? "")\"") }
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    private func listApps() -> ToolResult {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let all = WindowList.all()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let lines = apps.map { app -> String in
            let count = all.filter { $0.pid == app.processIdentifier && $0.layer == 0 && $0.bounds.width > 40 }.count
            return "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier)), \(count) window(s)" + (app.processIdentifier == front ? " — the user is using this app" : "")
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    private func openWindow(_ args: Args) throws -> ToolResult {
        let app = try args.requireString("app")
        // A new window becomes its app's key window; don't do that under the user.
        if let running = try windows.resolveApp(app).running {
            try waitForTurn(pid: running.processIdentifier, appName: running.localizedName ?? app)
        }
        let result = try windows.open(app: app, placement: WindowManager.Placement(name: args.string("placement")), trigger: args.string("trigger"))
        let w = result.window
        let frame = WindowList.info(w.id)?.bounds ?? .zero
        let text = "Opened window \(w.id) of \(w.appName) on your display (\(Int(frame.width))x\(Int(frame.height))). Next: get_window_state window_id=\(w.id).\nNotes: \(result.notes.joined(separator: "; "))"
        return ToolResult(text: text)
    }

    private func listWindows(_ args: Args) throws -> ToolResult {
        var lines = ["Your windows:"]
        let mine = windows.windows
        if mine.isEmpty { lines.append("  (none)") }
        for w in mine {
            let info = WindowList.info(w.id)
            lines.append("  \(w.id): \(w.appName) \"\(info?.title ?? "")\" [\(w.kind.rawValue)\(w.handedOff ? ", handed off" : "")]")
        }
        if let app = args.string("app") {
            let target = try windows.resolveApp(app)
            if let running = target.running {
                lines.append("\(target.name)'s other windows (the user's):")
                // Accessibility's window list holds only real windows (no menu-bar strips or panels' helpers).
                let others = AX.windows(running.processIdentifier).compactMap { ax -> (CGWindowID, AXUIElement)? in
                    guard let id = AX.windowID(ax), windows.window(id) == nil else { return nil }
                    return (id, ax)
                }
                if others.isEmpty { lines.append("  (none)") }
                for (id, ax) in others {
                    let size = AX.size(ax) ?? .zero
                    let minimized = AX.bool(ax, "AXMinimized") == true
                    lines.append("  \(id): \"\(AX.string(ax, "AXTitle") ?? "")\" \(Int(size.width))x\(Int(size.height))\(minimized ? " (minimized)" : "")")
                }
            } else {
                lines.append("\(target.name) isn't running.")
            }
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    private func borrowWindow(_ args: Args) throws -> ToolResult {
        let id = CGWindowID(try args.requireInt("window_id"))
        guard let info = WindowList.info(id) else { throw ToolError("no window \(id)") }
        let front = BCUFrontProcessPID()
        if front == info.pid {
            throw ToolError("the user is using \(info.owner) right now; borrowing its window would take it from them. Retry later.")
        }
        let w = try windows.borrow(id)
        return ToolResult(text: "Borrowed window \(w.id) of \(w.appName). It goes back to the user's screen on release_window.")
    }

    private func releaseWindow(_ args: Args) throws -> ToolResult {
        let id = CGWindowID(try args.requireInt("window_id"))
        if windows.window(id) == nil && WindowList.info(id) == nil {
            snapshots[id] = nil
            return ToolResult(text: "window \(id) is already closed")
        }
        let text = try windows.release(id, keepOpen: args.bool("keep_open") ?? false)
        snapshots[id] = nil
        return ToolResult(text: text)
    }

    private func getWindowState(_ args: Args) throws -> ToolResult {
        let (w, ax) = try agentWindow(args)
        let maxElements = args.int("max_elements") ?? 250
        let title = AX.string(ax, "AXTitle") ?? WindowList.info(w.id)?.title ?? ""
        var snap = AXSnapshot.take(window: ax, windowID: w.id, title: title, appName: w.appName, pid: w.pid, maxElements: maxElements)
        // Web content (Chromium, Electron) only builds its accessibility tree once
        // an assistive client asks. AXEnhancedUserInterface is the standard way
        // VoiceOver asks; set it once per app.
        if snap.nodes.count < 12 && !enhancedPids.contains(w.pid) {
            enhancedPids.insert(w.pid)
            AX.set(AX.app(w.pid), "AXEnhancedUserInterface", kCFBooleanTrue)
            sleepMs(700)
            snap = AXSnapshot.take(window: ax, windowID: w.id, title: title, appName: w.appName, pid: w.pid, maxElements: maxElements)
        }
        snapshots[w.id] = snap
        var images: [ToolImage] = []
        if args.bool("screenshot") ?? true, let img = try? Capture.window(w.id), let png = pngImage(img) {
            images.append(png)
        }
        return ToolResult(text: snap.text, images: images)
    }

    private func screenshot(_ args: Args) throws -> ToolResult {
        if args.int("window_id") != nil {
            let (w, _) = try agentWindow(args)
            let img = try Capture.window(w.id)
            guard let png = pngImage(img) else { throw ToolError("couldn't encode the screenshot") }
            return ToolResult(text: "Window \(w.id), \(img.width)x\(img.height)", images: [png])
        }
        guard let img = Capture.composite(display: display) else { throw ToolError("the agent display isn't running") }
        guard let png = pngImage(img) else { throw ToolError("couldn't encode the screenshot") }
        return ToolResult(text: "Agent display, \(img.width)x\(img.height)", images: [png])
    }

    private func click(_ args: Args) throws -> ToolResult {
        let (w, ax) = try agentWindow(args)
        let button: Input.Button = args.string("button")?.lowercased() == "right" ? .right : .left
        let count = args.int("count") ?? 1
        if args.int("element") != nil {
            let n = try node(args, window: w)
            if button == .left && count == 1 && n.actions.contains("AXPress") {
                let err = guarded(w, cause: "pressing an element") { AX.perform(n.element, "AXPress") }
                if err == .success { return ToolResult(text: "Pressed element \(n.index) (\(n.role)) through accessibility.") }
            }
            if button == .right && n.actions.contains("AXShowMenu") {
                let err = guarded(w, cause: "opening a context menu") { AX.perform(n.element, "AXShowMenu") }
                if err == .success { return ToolResult(text: "Opened the context menu of element \(n.index). Call get_window_state to see it.") }
            }
            let p = n.frame.center
            try keyed(w, cause: "clicking") { try Input.click(pid: w.pid, windowID: w.id, at: p, button: button, count: count) }
            return ToolResult(text: "Clicked element \(n.index) at its center.")
        }
        let p = try globalPoint(args, window: ax)
        try keyed(w, cause: "clicking") { try Input.click(pid: w.pid, windowID: w.id, at: p, button: button, count: count) }
        return ToolResult(text: "Clicked at (\(Int(args.double("x") ?? 0)), \(Int(args.double("y") ?? 0))).")
    }

    private func setValue(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let n = try node(args, window: w)
        let value = try args.requireString("value")
        let err = guarded(w, cause: "setting a value") { AX.set(n.element, "AXValue", value as CFString) }
        guard err == .success else {
            throw ToolError("couldn't set element \(n.index)'s value (\(AX.errorName(err))). Try type_text with element=\(n.index).")
        }
        sleepMs(80)
        let now = AX.string(n.element, "AXValue") ?? ""
        if now == value { return ToolResult(text: "Set element \(n.index) to \"\(value)\" (verified).") }
        return ToolResult(text: "Set element \(n.index); reading it back gives \"\(now.prefix(200))\". Some apps only echo accessibility writes: if the page didn't react, use type_text with element=\(n.index).")
    }

    private func performAction(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let n = try node(args, window: w)
        var action = try args.requireString("action")
        if !action.hasPrefix("AX") { action = "AX" + action.prefix(1).uppercased() + action.dropFirst() }
        let err = guarded(w, cause: "performing \(action)") { AX.perform(n.element, action) }
        guard err == .success else {
            throw ToolError("\(action) on element \(n.index) failed: \(AX.errorName(err)). Its actions: \(n.actions.joined(separator: ", "))")
        }
        return ToolResult(text: "Performed \(action) on element \(n.index).")
    }

    private func typeText(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let text = try args.requireString("text")
        var target: AXNode?
        if args.int("element") != nil { target = try node(args, window: w) }

        // Accessibility insertion first: no keyboard focus involved.
        if let n = target, !text.contains("\n"), !text.contains("\t"), AX.isSettable(n.element, "AXSelectedText") {
            let before = AX.string(n.element, "AXValue") ?? ""
            let err = guarded(w, cause: "typing") { () -> AXError in
                AX.set(n.element, "AXFocused", kCFBooleanTrue)
                return AX.set(n.element, "AXSelectedText", text as CFString)
            }
            sleepMs(80)
            let after = AX.string(n.element, "AXValue") ?? ""
            if err == .success && after != before && after.contains(text) {
                return ToolResult(text: "Inserted the text into element \(n.index) through accessibility.")
            }
        }
        try keyed(w, cause: "typing") {
            if let n = target {
                AX.set(n.element, "AXFocused", kCFBooleanTrue)
                sleepMs(50)
            }
            try Input.typeText(pid: w.pid, text)
        }
        return ToolResult(text: "Typed \(text.count) characters with keystrokes.")
    }

    private func pressKey(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let key = try args.requireString("key")
        let mods = args.strings("modifiers") ?? []
        try keyed(w, cause: "pressing \((mods + [key]).joined(separator: "+"))") {
            try Input.pressKey(pid: w.pid, key: key, modifiers: mods)
        }
        return ToolResult(text: "Pressed \((mods + [key]).joined(separator: "+")).")
    }

    private func scroll(_ args: Args) throws -> ToolResult {
        let (w, ax) = try agentWindow(args)
        let p: CGPoint
        if args.int("element") != nil {
            p = try node(args, window: w).frame.center
        } else if args.double("x") != nil {
            p = try globalPoint(args, window: ax)
        } else {
            guard let f = AX.frame(ax) else { throw ToolError("can't read the window frame") }
            p = f.center
        }
        let dx = args.int("dx") ?? 0, dy = args.int("dy") ?? 0
        guard dx != 0 || dy != 0 else { throw ToolError("give dx or dy") }
        try guarded(w, cause: "scrolling") { try Input.scroll(pid: w.pid, windowID: w.id, at: p, dx: dx, dy: dy) }
        return ToolResult(text: "Scrolled dx=\(dx) dy=\(dy).")
    }

    private func drag(_ args: Args) throws -> ToolResult {
        let (w, ax) = try agentWindow(args)
        guard let f = AX.frame(ax),
              let fx = args.double("from_x"), let fy = args.double("from_y"),
              let tx = args.double("to_x"), let ty = args.double("to_y") else { throw ToolError("give from_x, from_y, to_x, to_y") }
        let from = CGPoint(x: f.minX + fx, y: f.minY + fy), to = CGPoint(x: f.minX + tx, y: f.minY + ty)
        try keyed(w, cause: "dragging") { try Input.drag(pid: w.pid, windowID: w.id, from: from, to: to) }
        return ToolResult(text: "Dragged from (\(Int(fx)),\(Int(fy))) to (\(Int(tx)),\(Int(ty))).")
    }

    private func pressMenuItem(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        guard let path = args.strings("path"), !path.isEmpty else { throw ToolError("give path, e.g. [\"File\", \"Save…\"]") }
        guard let bar = AX.element(AX.app(w.pid), "AXMenuBar") else { throw ToolError("\(w.appName) has no accessible menu bar") }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces) }
        var current: AXUIElement = bar
        var item: AXUIElement?
        for (i, title) in path.enumerated() {
            let container = i == 0 ? current : (AX.children(current).first { AX.string($0, "AXRole") == "AXMenu" } ?? current)
            guard let next = AX.children(container).first(where: { norm(AX.string($0, "AXTitle") ?? "") == norm(title) }) else {
                let options = AX.children(container).compactMap { AX.string($0, "AXTitle") }.filter { !$0.isEmpty }
                throw ToolError("no menu item \"\(title)\". Options here: \(options.joined(separator: ", "))")
            }
            current = next
            item = next
        }
        guard let target = item else { throw ToolError("empty path") }
        if AX.bool(target, "AXEnabled") == false { throw ToolError("\"\(path.last!)\" is disabled right now") }
        let err = try keyed(w, cause: "choosing \(path.joined(separator: " > "))") { () -> AXError in
            let e = AX.perform(target, "AXPress")
            sleepMs(200)
            return e
        }
        guard err == .success else { throw ToolError("pressing \(path.joined(separator: " > ")) failed: \(AX.errorName(err))") }
        return ToolResult(text: "Chose \(path.joined(separator: " > ")).")
    }

    private func handoff(_ args: Args) throws -> ToolResult {
        let id = CGWindowID(try args.requireInt("window_id"))
        let reason = try args.requireString("reason")
        try windows.handoff(id, reason: reason)
        log("Handed off: \(reason)")
        return ToolResult(text: "Window \(id) is on the user's screen with your reason shown in the menu bar. Stop and wait for the user; call take_back when they say they're done.")
    }

    private func takeBack(_ args: Args) throws -> ToolResult {
        let id = CGWindowID(try args.requireInt("window_id"))
        try windows.takeBack(id)
        return ToolResult(text: "Window \(id) is back on your display.")
    }

    private func guardReport() -> ToolResult {
        let events = focusGuard.recentEvents
        if events.isEmpty { return ToolResult(text: "No guard events: nothing has touched the user's focus, cursor or screen.") }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return ToolResult(text: events.map { "\(f.string(from: $0.time)) \($0.summary)" }.joined(separator: "\n"))
    }
}

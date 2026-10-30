import AppKit
import BCUShared
import CPrivate

public enum EngineStatus: Equatable {
    case idle
    case working(String)
    case waiting(String)
    case paused
    /// The user is driving the agent display from the expanded view.
    case userInControl
}

public struct ActivityItem {
    public let time: Date
    public let text: String
    public let isError: Bool
}

/// One agent session: its own display (created when it first needs one),
/// windows, activity, pause and take-over. Runs the session's tool calls one
/// at a time on its own queue; input to apps is serialized across sessions.
public final class Engine {
    public let sessionID: String
    /// Shown in the menu bar, e.g. "Claude Code".
    public let label: String
    public let display: AgentDisplay
    public let focusGuard: FocusGuard
    public let windows: WindowManager
    /// Sound from apps only this session uses goes here instead of the speakers.
    public let audio: SessionAudio

    /// Called on the main thread whenever status, activity or windows change.
    public var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "bcu.engine")
    private let stateLock = NSLock()
    private var snapshots: [CGWindowID: AXSnapshotResult] = [:]
    /// When the agent last acted on each window, so a state read can wait for it to settle.
    private var lastActionMs: [CGWindowID: Double] = [:]
    private var enhancedPids: Set<pid_t> = []
    private var _activity: [ActivityItem] = []
    private var _paused = false
    private var _userInControl = false
    private lazy var testRemote = RemoteControl(engine: self)
    private var _waitingReason: String?
    private var _busy: String?
    private var lastCallMs = 0.0

    /// Input to apps (key-window swaps, clicks, keys) from any session goes
    /// one at a time: two sessions in the same app would fight over its key window.
    public static let inputLock = NSRecursiveLock()

    public init(sessionID: String, label: String, focusGuard: FocusGuard, width: Int = AgentDisplay.defaultWidth, height: Int = AgentDisplay.defaultHeight) {
        self.sessionID = sessionID
        self.label = label
        self.focusGuard = focusGuard
        display = AgentDisplay(width: width, height: height)
        windows = WindowManager(display: display, focusGuard: focusGuard, sessionKey: sessionID)
        let safe = label.replacingOccurrences(of: " ", with: "-").lowercased()
        audio = SessionAudio(name: "\(safe)-\(sessionID.prefix(8))")
    }

    /// Create the session's display if it doesn't exist yet. Any thread.
    public func ensureDisplay() throws {
        guard !display.isRunning else { return }
        var failure: Error?
        let work = {
            do {
                try self.display.start()
                self.windows.startWatchdog()
            } catch { failure = error }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        if let failure { throw failure }
        log("Created \(display.slot == 0 ? "the agent display" : "agent display \(display.slot + 1)")")
    }

    /// No display, no windows and no calls for `idleMs`: the session can be forgotten.
    public func isDormant(idleMs: Double) -> Bool {
        guard !display.isRunning, windows.windows.isEmpty, !userInControl else { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        return _busy == nil && nowMs() - lastCallMs > idleMs
    }

    /// Remove the display once the session has had no windows and no calls
    /// for `idleMs`, so an unused display doesn't sit in the user's arrangement.
    public func tearDownIfIdle(idleMs: Double) {
        queue.async {
            guard self.display.isRunning, self.windows.windows.isEmpty, !self.userInControl else { return }
            self.stateLock.lock()
            let idle = self._busy == nil && nowMs() - self.lastCallMs > idleMs
            self.stateLock.unlock()
            guard idle else { return }
            DispatchQueue.main.sync {
                self.windows.stopWatchdog()
                self.display.stop()
            }
            self.snapshots.removeAll()
            self.audio.end()
            self.log("Removed the agent display: no windows for a while")
        }
    }

    /// Release windows (closing opened, returning borrowed) on the session's
    /// queue; `group` is left when done. Release doesn't need the main thread,
    /// which may be busy quitting.
    public func releaseForShutdown(_ group: DispatchGroup) {
        group.enter()
        queue.async {
            _ = self.windows.releaseAll()
            group.leave()
        }
    }

    /// Main thread, after the windows are released, so nothing lands on the
    /// user's screen when the display goes away.
    public func finishShutdown() {
        windows.stopWatchdog()
        display.stop()
        audio.end()
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
        if _userInControl { return .userInControl }
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

    /// Tell the menu bar something changed (the hub forwards it).
    func changed() {
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

    /// The user is driving the agent display from the expanded view. The
    /// agent's actions are refused until they give it back.
    public var userInControl: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _userInControl
    }

    public func setUserInControl(_ value: Bool) {
        stateLock.lock()
        let was = _userInControl
        _userInControl = value
        stateLock.unlock()
        windows.userArranging = value
        if was != value { log(value ? "You took over the agent display" : "You gave the agent display back") }
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
            // Closing a window the user is working in would pull it out from under them.
            if userInControl && (!readOnly.contains(tool) || tool == "release_window") {
                return .error("The user took over your display and is using your windows. Wait and retry later, or tell the user you're blocked.")
            }
            if paused && !readOnly.contains(tool) {
                return .error("Paused by the user from the menu bar. Wait and retry later, or tell the user you're blocked.")
            }
            let monitored = !readOnly.contains(tool) || tool == "get_window_state"
            let startMs = nowMs()
            if monitored { focusGuard.startMonitor() }
            do {
                var result = try run(tool: tool, args: Args(args))
                if monitored, let focusNote = focusGuard.stopMonitor() {
                    focusGuard.record("\(tool): \(focusNote)")
                    result.text += "\n[focus guard] \(focusNote)"
                }
                if tool != "status" && tool != "guard_report" {
                    log("\(tool) (\(Int(nowMs() - startMs)) ms): \(result.text.split(separator: "\n").first.map(String.init) ?? "")")
                }
                return result
            } catch {
                if monitored { _ = focusGuard.stopMonitor(tailMs: 0) }
                log("\(tool) failed after \(Int(nowMs() - startMs)) ms: \(error)", error: true)
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
        case "batch": return "Working"
        case "scroll": return "Scrolling"
        default: return "Working"
        }
    }

    private func run(tool: String, args: Args) throws -> ToolResult {
        defer {
            if Self.batchable.contains(tool), tool != "wait", let id = args.int("window_id") {
                lastActionMs[CGWindowID(id)] = nowMs()
            }
        }
        // Opening or borrowing a window is what needs a display.
        if tool == "open_window" || tool == "borrow_window" { try ensureDisplay() }
        return try dispatch(tool: tool, args: args)
    }

    private func dispatch(tool: String, args: Args) throws -> ToolResult {
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
        case "batch": return try batch(args)
        // Maintenance, not in the agent tool catalog.
        case "admin_close_window":
            return ToolResult(text: windows.closeAny(CGWindowID(try args.requireInt("window_id"))) ? "closed" : "failed")
        case "admin_move_to_user":
            var frame: CGRect?
            if let x = args.double("x"), let y = args.double("y"), let w = args.double("w"), let h = args.double("h") { frame = CGRect(x: x, y: y, width: w, height: h) }
            return ToolResult(text: windows.moveToUser(CGWindowID(try args.requireInt("window_id")), frame: frame) ? "moved" : "failed")
        case "admin_type_hid":
            return TestHarness.shared.startTyping(try args.requireString("text"), intervalMs: args.double("interval_ms") ?? 35,
                                                  onlyPid: args.int("pid").map { pid_t($0) })
        case "admin_swap_test":
            // Experiment: which records, in what spacing, move key from one window to another.
            let pid = pid_t(try args.requireInt("pid"))
            let from = CGWindowID(try args.requireInt("from"))
            let to = CGWindowID(try args.requireInt("to"))
            let defocus = args.bool("defocus") ?? true
            let focus = args.bool("focus") ?? true
            let makeKey = args.bool("make_key") ?? true
            let settle = args.double("settle_ms") ?? 0
            let t0 = nowMs()
            if defocus { _ = BCUPostFocusRecord(pid, from, false); sleepMs(settle) }
            if focus { _ = BCUPostFocusRecord(pid, to, true); sleepMs(settle) }
            if makeKey { _ = BCUPostMakeKeyRecords(pid, to) }
            let deadline = nowMs() + 600
            while AX.focusedWindowID(pid) != to && nowMs() < deadline { usleep(1000) }
            let ok = AX.focusedWindowID(pid) == to
            return ToolResult(text: "\(ok ? "OK" : "FAIL") after \(Int(nowMs() - t0)) ms (key now \(AX.focusedWindowID(pid).map(String.init) ?? "none"))")
        case "admin_focus_state":
            let pid = pid_t(try args.requireInt("pid"))
            return ToolResult(text: "front=\(BCUFrontProcessPID()) keyWindow=\(AX.focusedWindowID(pid).map(String.init) ?? "none")")
        case "admin_activate":
            let pid = pid_t(try args.requireInt("pid"))
            let wid = CGWindowID(args.int("window_id") ?? 0)
            let r = BCUSetFrontProcess(pid, wid, 0x200)
            if wid != 0 { _ = BCUPostMakeKeyRecords(pid, wid) }
            sleepMs(300)
            return ToolResult(text: "setFront=\(r) front=\(BCUFrontProcessPID()) keyWindow=\(AX.focusedWindowID(pid).map(String.init) ?? "none")")
        case "admin_ax_set":
            let (w, _) = try agentWindow(args)
            let n = try node(args, window: w)
            let attr = try args.requireString("attr")
            let value: AnyObject
            if let b = args.bool("bool") { value = b ? kCFBooleanTrue : kCFBooleanFalse } else { value = try args.requireString("value") as CFString }
            let err = AX.set(n.element, attr, value)
            return ToolResult(text: "\(attr) -> \(AX.errorName(err)); value now \"\(AX.string(n.element, "AXValue") ?? "")\"")
        case "admin_click_raw":
            let (w, ax) = try agentWindow(args)
            let p: CGPoint
            if args.int("element") != nil { p = try node(args, window: w).frame.center } else { p = try globalPoint(args, window: ax) }
            try Input.click(pid: w.pid, windowID: w.id, at: p)
            return ToolResult(text: "raw click posted")
        case "admin_flicker":
            // Experiment: does moving key focus show up in the user's window?
            let pid = pid_t(try args.requireInt("pid"))
            let user = CGWindowID(try args.requireInt("user_window"))
            let agent = CGWindowID(try args.requireInt("agent_window"))
            let mode = args.string("mode") ?? "none"
            let settle = args.double("settle_ms") ?? 5
            let hold = args.double("hold_ms") ?? 0
            var rect: CGRect?
            if let rx = args.double("rx"), let ry = args.double("ry"), let rw = args.double("rw"), let rh = args.double("rh") { rect = CGRect(x: rx, y: ry, width: rw, height: rh) }
            let text = FlickerProbe.run(userWindow: user, rect: rect, options: UInt32(args.int("options") ?? 0), saveDir: args.string("save_dir"), durationMs: args.double("duration_ms") ?? 500) {
                func records(_ from: CGWindowID, _ to: CGWindowID) {
                    _ = BCUPostFocusRecord(pid, from, false); if settle > 0 { sleepMs(settle) }
                    _ = BCUPostFocusRecord(pid, to, true); if settle > 0 { sleepMs(settle) }
                    _ = BCUPostMakeKeyRecords(pid, to)
                }
                func waitKey(_ id: CGWindowID) -> Double {
                    let t = nowMs()
                    while AX.focusedWindowID(pid) != id && nowMs() - t < 400 { usleep(500) }
                    return nowMs() - t
                }
                switch mode {
                case "swap":
                    records(user, agent)
                    let a = waitKey(agent)
                    sleepMs(hold)
                    records(agent, user)
                    let b = waitKey(user)
                    return "swap: agent key after \(Int(a)) ms, back after \(Int(b)) ms"
                case "pipelined":
                    records(user, agent)
                    sleepMs(hold)
                    records(agent, user)
                    let b = waitKey(user)
                    return "pipelined: settled \(Int(b)) ms after posting"
                case "click":
                    if let w = windows.window(agent), let ax = AX.window(pid: pid, id: agent), let f = AX.frame(ax) {
                        try? Input.click(pid: w.pid, windowID: agent, at: CGPoint(x: f.midX, y: f.maxY - 40))
                    }
                    let a = waitKey(agent)
                    records(agent, user)
                    let b = waitKey(user)
                    return "click: agent key after \(Int(a)) ms, user key again after \(Int(b)) ms"
                default:
                    return "no action"
                }
            }
            return ToolResult(text: text)
        case "admin_remote":
            // Drive the remote-control path the expanded view uses, without the view.
            let (w, ax) = try agentWindow(args)
            guard let f = AX.frame(ax) else { throw ToolError("no frame") }
            let p = CGPoint(x: f.minX + (args.double("x") ?? 0), y: f.minY + (args.double("y") ?? 0))
            let remote = testRemote
            let target = remote.window(at: p).map { "\($0.id) \($0.owner) layer \($0.layer)" } ?? "none"
            switch args.string("action") ?? "click" {
            case "click":
                remote.mouse(.leftMouseDown, at: p, button: 0, clickCount: 1, flags: [])
                remote.mouse(.leftMouseUp, at: p, button: 0, clickCount: 1, flags: [])
            case "type":
                let src = CGEventSource(stateID: .hidSystemState)
                for ch in try args.requireString("text") {
                    let (code, shift) = ch == "\n" ? (CGKeyCode(36), false) : try KeyMap.code(for: String(ch))
                    for down in [true, false] {
                        guard let k = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
                        k.flags = shift ? .maskShift : []
                        remote.key(k)
                    }
                }
            case "key":
                let (code, _) = try KeyMap.code(for: try args.requireString("key"))
                let flags = KeyMap.flags((args.raw["modifiers"] as? [String]) ?? [])
                for down in [true, false] {
                    guard let k = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
                    k.flags = flags
                    remote.key(k)
                }
            case "double":
                for n in 1...2 {
                    remote.mouse(.leftMouseDown, at: p, button: 0, clickCount: n, flags: [])
                    remote.mouse(.leftMouseUp, at: p, button: 0, clickCount: n, flags: [])
                    remote.flush()
                    sleepMs(60)
                }
            case "choose":
                let path = (args.raw["path"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                remote.chooseMenuItem(token: remote.latestMenuToken, path: path)
                sleepMs(900)
            case "move":
                remote.mouse(.mouseMoved, at: p, button: 0, clickCount: 0, flags: [])
            case "right":
                remote.mouse(.rightMouseDown, at: p, button: 1, clickCount: 1, flags: [])
                remote.mouse(.rightMouseUp, at: p, button: 1, clickCount: 1, flags: [])
            case "drag":
                let q = CGPoint(x: f.minX + (args.double("to_x") ?? 0), y: f.minY + (args.double("to_y") ?? 0))
                remote.mouse(.leftMouseDown, at: p, button: 0, clickCount: 1, flags: [])
                for i in 1...10 {
                    let t = CGFloat(i) / 10
                    remote.mouse(.leftMouseDragged, at: CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t), button: 0, clickCount: 1, flags: [])
                    remote.flush(); sleepMs(16)
                }
                remote.mouse(.leftMouseUp, at: q, button: 0, clickCount: 1, flags: [])
            case "scroll":
                if let s = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(args.int("dy") ?? -400), wheel2: 0, wheel3: 0) {
                    remote.scroll(s, at: p)
                }
            default: throw ToolError("action is click, type, key or scroll")
            }
            remote.flush()
            return ToolResult(text: "posted to \(target); app key window \(AX.focusedWindowID(w.pid).map(String.init) ?? "none"), front pid \(BCUFrontProcessPID())")
        case "admin_hit":
            let (w, ax) = try agentWindow(args)
            guard let f = AX.frame(ax) else { throw ToolError("no frame") }
            let p = CGPoint(x: f.minX + (args.double("x") ?? 0), y: f.minY + (args.double("y") ?? 0))
            var el: AXUIElement?
            let err = AXUIElementCopyElementAtPosition(AX.app(w.pid), Float(p.x), Float(p.y), &el)
            var lines = ["hit at \(p): \(AX.errorName(err))"]
            var cur = el
            for _ in 0..<6 {
                guard let e = cur else { break }
                lines.append("\(AX.string(e, "AXRole") ?? "?") \"\(AX.string(e, "AXTitle") ?? "")\" actions \(AX.actions(e))")
                cur = AX.element(e, "AXParent")
            }
            return ToolResult(text: lines.joined(separator: "\n"))
        case "admin_cursor_escape":
            return ToolResult(text: focusGuard.escapeTest(via: args.string("via") ?? "warp"))
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

    /// Is the user in this app right now (so its key window is theirs)?
    private func userIsIn(_ pid: pid_t) -> Bool {
        BCUFrontProcessPID() == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Run `body` with the window as its app's key window, under the guard.
    /// Keystrokes and pixel clicks go to the app's key window, so the agent's
    /// window is made key for the length of `body` and key goes straight back
    /// to the user's window. The swap takes a few milliseconds and doesn't
    /// repaint the user's window. If the user is in that app, their keys and
    /// clicks are held during the swap and replayed after, so none of them
    /// land in the agent's window.
    private func keyed<T>(_ w: AgentWindow, cause: String, _ body: () throws -> T) throws -> T {
        if paused { throw ToolError("paused by the user") }
        if userInControl { throw ToolError("the user took over your display") }
        Self.inputLock.lock()
        defer { Self.inputLock.unlock() }
        focusGuard.beginAction(pid: w.pid, cause: cause)
        windows.noteBefore(pid: w.pid)
        defer { focusGuard.endAction(pid: w.pid) }
        let shared = userIsIn(w.pid)
        if shared { focusGuard.beginHold() }
        defer { if shared { focusGuard.endHold() } }
        let scope = try KeyScope.enter(pid: w.pid, window: w.id)
        defer { scope.exit() }
        return try body()
    }

    private func guarded<T>(_ w: AgentWindow, cause: String, _ body: () throws -> T) rethrows -> T {
        Self.inputLock.lock()
        defer { Self.inputLock.unlock() }
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
        lines.append("Agent display: \(display.width)x\(display.height) points" + (display.isRunning ? "" : " (created when you open your first window)"))
        if let b = Self.defaultBrowser() {
            lines.append("User's default browser: \(b.name) (\(b.bundleID)). Use it when a task needs a browser.")
        }
        lines.append("Permissions: accessibility \(AX.isTrusted ? "granted" : "MISSING"), screen recording \(Capture.hasPermission ? "granted" : "MISSING")")
        if paused { lines.append("Paused by the user.") }
        if !audio.routedApps.isEmpty {
            lines.append("Audio from \(audio.routedApps.joined(separator: ", ")) is muted on the speakers and recorded to \(audio.url.path) (deleted when your display is removed).")
        }
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
        // A new window becomes its app's key window until it's handed back;
        // hold the user's input meanwhile if they're in that app.
        let shared = (try windows.resolveApp(app).running).map { userIsIn($0.processIdentifier) } ?? false
        if shared { focusGuard.beginHold() }
        defer { if shared { focusGuard.endHold() } }
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
        // Web content (Chromium, Electron) only builds its full accessibility
        // tree, with press actions on links and buttons, once an assistive
        // client asks. AXEnhancedUserInterface is the standard way VoiceOver
        // asks; set it once per app.
        var fresh = false
        if !enhancedPids.contains(w.pid) {
            enhancedPids.insert(w.pid)
            fresh = AX.bool(AX.app(w.pid), "AXEnhancedUserInterface") != true
            AX.set(AX.app(w.pid), "AXEnhancedUserInterface", kCFBooleanTrue)
            if fresh { sleepMs(300) }
        }
        let previous = snapshots[w.id]
        func take() -> AXSnapshotResult {
            let popups = popupWindows(of: w, frame: AX.frame(ax))
            return AXSnapshot.take(window: ax, windowID: w.id, title: AX.string(ax, "AXTitle") ?? title, appName: w.appName, pid: w.pid,
                                   maxElements: maxElements, popups: popups, previous: previous)
        }
        var snap = take()
        if fresh && snap.nodes.count < 12 {
            sleepMs(700)
            snap = take()
        }
        // Right after an action, wait for the window to settle: no web area
        // loading, and nothing changing for 400 ms. Up to 5 s from the action.
        if let acted = lastActionMs[w.id], nowMs() - acted < 5000 {
            let deadline = acted + 5000
            let earliest = acted + 400
            if nowMs() < earliest { sleepMs(earliest - nowMs()); snap = take() }
            var stableSince = nowMs()
            while nowMs() < deadline {
                if !isLoading(snap) && nowMs() - stableSince >= 400 { break }
                sleepMs(130)
                let again = take()
                if again.text != snap.text { stableSince = nowMs() }
                snap = again
            }
            lastActionMs[w.id] = nil
        }
        snapshots[w.id] = snap
        var images: [ToolImage] = []
        if args.bool("screenshot") ?? true, let img = try? Capture.windowInPoints(w.id, display: display.bounds), let png = pngImage(img) {
            images.append(png)
        }
        let full = args.bool("full") ?? false
        if !full, let previous, let changes = AXSnapshot.diff(from: previous, to: snap) {
            return ToolResult(text: changes, images: images)
        }
        var text = snap.text
        if snap.renumbered { text += "\n(Most elements are new, so numbering restarted; numbers from earlier reads no longer apply.)" }
        return ToolResult(text: text, images: images)
    }

    /// A web area in the snapshot is still loading (the standard AXLoaded,
    /// AXLoadingProgress and AXElementBusy attributes).
    private func isLoading(_ snap: AXSnapshotResult) -> Bool {
        snap.nodes.values.contains { n in
            guard n.role == "AXWebArea" else { return false }
            if AX.bool(n.element, "AXLoaded") == false { return true }
            if AX.bool(n.element, "AXElementBusy") == true { return true }
            if let p = AX.double(n.element, "AXLoadingProgress"), p < 1 { return true }
            return false
        }
    }

    // MARK: Batch

    private static let batchable: Set<String> = ["click", "set_value", "perform_action", "type_text", "press_key",
                                                 "scroll", "drag", "press_menu_item", "wait"]

    /// Run several actions on a window in one call, in order, stopping at the
    /// first failure, then optionally read the window's state once.
    private func batch(_ args: Args) throws -> ToolResult {
        guard let steps = args.raw["actions"] as? [JSONObject], !steps.isEmpty else {
            throw ToolError("`actions` must be a non-empty array of objects like {\"tool\": \"click\", \"element\": 4}")
        }
        if steps.count > 40 { throw ToolError("at most 40 actions per batch") }
        let defaultWindow = args.int("window_id")
        // Check every step before running any.
        for (i, step) in steps.enumerated() {
            guard let tool = step["tool"] as? String else { throw ToolError("action \(i + 1) has no `tool`") }
            guard Self.batchable.contains(tool) else {
                throw ToolError("action \(i + 1): `\(tool)` can't be batched. Allowed: \(Self.batchable.sorted().joined(separator: ", ")). Read state with the batch's `state` option.")
            }
            if tool != "wait" && step["window_id"] == nil && defaultWindow == nil {
                throw ToolError("action \(i + 1) needs a window_id (or set window_id on the batch)")
            }
        }
        var lines: [String] = []
        var lastWindow = defaultWindow
        var failed = false
        for (i, step) in steps.enumerated() {
            let tool = step["tool"] as! String
            var stepArgs = step
            stepArgs["tool"] = nil
            if stepArgs["window_id"] == nil, let d = defaultWindow { stepArgs["window_id"] = d }
            if let wid = Args(stepArgs).int("window_id") { lastWindow = wid }
            if tool == "wait" {
                let ms = min(max(Args(stepArgs).double("ms") ?? 500, 0), 5000)
                sleepMs(ms)
                lines.append("\(i + 1). wait: \(Int(ms)) ms")
                continue
            }
            do {
                let r = try run(tool: tool, args: Args(stepArgs))
                lines.append("\(i + 1). \(tool): \(r.text.split(separator: "\n").first.map(String.init) ?? "done")")
            } catch {
                lines.append("\(i + 1). \(tool) FAILED: \(error)")
                if i + 2 == steps.count { lines.append("Stopped; action \(i + 2) didn't run.") }
                if i + 2 < steps.count { lines.append("Stopped; actions \(i + 2)–\(steps.count) didn't run.") }
                failed = true
                break
            }
        }
        var images: [ToolImage] = []
        if args.bool("state") ?? true, let wid = lastWindow, windows.window(CGWindowID(wid)) != nil {
            var stateArgs: JSONObject = ["window_id": wid, "screenshot": args.bool("screenshot") ?? false]
            if let full = args.bool("full") { stateArgs["full"] = full }
            if let m = args.int("max_elements") { stateArgs["max_elements"] = m }
            if let state = try? getWindowState(Args(stateArgs)) {
                lines.append("")
                lines.append(state.text)
                images = state.images
            }
        }
        var result = ToolResult(text: lines.joined(separator: "\n"), images: images)
        if failed { result.isError = true }
        return result
    }

    /// The app's other accessibility windows that aren't standard windows and
    /// sit over this one: suggestion lists, menus, dropdowns.
    private func popupWindows(of w: AgentWindow, frame: CGRect?) -> [AXUIElement] {
        guard let frame else { return [] }
        return AX.windows(w.pid).filter { other in
            guard AX.string(other, "AXSubrole") != "AXStandardWindow",
                  let f = AX.frame(other), f.width > 4, f.height > 4, f.intersects(frame) else { return false }
            if let id = AX.windowID(other), id == w.id { return false }
            return true
        }
    }

    private func screenshot(_ args: Args) throws -> ToolResult {
        if args.int("window_id") != nil {
            let (w, _) = try agentWindow(args)
            let img = try Capture.windowInPoints(w.id, display: display.bounds)
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
        // The tree lists actions as "showmenu"; match that to the element's own "AXShowMenu".
        let bare = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        if let own = n.actions.first(where: { $0.hasPrefix("AX") && $0.dropFirst(2).lowercased() == bare.lowercased() }) {
            action = own
        } else if !action.hasPrefix("AX") {
            action = "AX" + action.prefix(1).uppercased() + action.dropFirst()
        }
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
        if let n = target {
            guarded(w, cause: "focusing") { _ = AX.set(n.element, "AXFocused", kCFBooleanTrue) }
            sleepMs(50)
        }
        // While the user is in the same app their input is held during each
        // swap, so type in short bursts to keep that delay small.
        let chunk = userIsIn(w.pid) ? 16 : Int.max
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(chunk)
            rest = rest.dropFirst(piece.count)
            try keyed(w, cause: "typing") { try Input.typeText(pid: w.pid, String(piece)) }
            if !rest.isEmpty { sleepMs(40) }
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

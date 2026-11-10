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

/// Where an agent action lands, so the previews can draw a cursor going there.
public struct AgentPointer {
    public enum Kind {
        case move
        case click
        case drag(to: CGPoint)
    }
    /// Global (top-left origin) point on the agent display.
    public let point: CGPoint
    public let kind: Kind
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
    /// The host app that shows this session in its own UI (`bcu mcp --host`), if any.
    public let host: String?
    public let display: AgentDisplay
    public let focusGuard: FocusGuard
    public let windows: WindowManager
    /// Sound from apps only this session uses goes here instead of the speakers.
    public let audio: SessionAudio
    /// Keeps what the display showed, for the history viewer.
    let recorder: SessionRecorder

    /// A frame of the live preview (the whole display), for the history.
    public func recordPreview(_ image: CGImage) { recorder.previewFrame(image) }

    /// Where this session is recorded, or nil for not at all. Set by `Hub`
    /// from what the session's host chose (`Hub.setRecordings`).
    func setRecordings(_ store: Recordings?) { recorder.setStore(store) }

    /// Called on the main thread whenever status, activity or windows change.
    public var onChange: (() -> Void)?

    /// Posted on the main thread with the engine as object and an
    /// `AgentPointer` under "pointer" just before an action lands somewhere.
    public static let pointerNotification = Notification.Name("bcu.agentPointer")
    private var _lastPointer: CGPoint?
    /// Where the last action landed, for a preview that opens later.
    public var lastPointer: CGPoint? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastPointer
    }

    private let queue = DispatchQueue(label: "bcu.engine")
    private let stateLock = NSLock()
    private var snapshots: [CGWindowID: AXSnapshotResult] = [:]
    /// When the agent last acted on each window, so a state read can wait for it to settle.
    private var lastActionMs: [CGWindowID: Double] = [:]
    private var enhancedPids: Set<pid_t> = []
    /// The text element that had focus in each window the last time it was
    /// key, for typing into it later without making the window key, with
    /// its selection and value then: a window that isn't key may not report
    /// its selection (after cmd+A, typing should replace, not append).
    private struct TextFocus {
        let element: AXUIElement
        var range: CFRange?
        var value: String
    }
    private var focusedText: [CGWindowID: TextFocus] = [:]
    /// Steps that take key focus in the app the user is in wait for a pause
    /// in their input (see `QuietWait`), within this session's budget.
    private let waitBudget = WaitBudget()
    /// The current step passed `priority: "now"`: no waiting for the user.
    private var priorityNow = false
    /// Waits for the user during the current call, for its result.
    private var waitNotes: [String] = []
    /// Waits for other agents (a free display, their turn at an app's key
    /// window) during the current call, for its result.
    private var agentWaitNotes: [String] = []
    /// The still copy over the user's window and the hold on their input,
    /// kept across back-to-back key-focus steps in a batch so the user gets
    /// one short freeze instead of several.
    private var cover: SwapCover?
    private var batching = false
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
    /// How long `open_window` waits for a free display when all are taken.
    /// Under Codex's default 60 s tool timeout.
    static let displayWaitS: TimeInterval = 45
    /// Another agent's window keeps its app's key for this long after that
    /// agent last touched it (`awaitAgentTurn`), but no one waits longer
    /// than `agentWaitMaxMs` for it.
    static let agentLeaseMs = 6000.0
    static let agentWaitMaxMs = 20000.0

    public init(sessionID: String, label: String, focusGuard: FocusGuard, host: String? = nil,
                width: Int = AgentDisplay.defaultWidth, height: Int = AgentDisplay.defaultHeight) {
        self.sessionID = sessionID
        self.label = label
        self.host = host
        self.focusGuard = focusGuard
        display = AgentDisplay(width: width, height: height)
        windows = WindowManager(display: display, focusGuard: focusGuard, sessionKey: sessionID)
        let safe = label.replacingOccurrences(of: " ", with: "-").lowercased()
        audio = SessionAudio(name: "\(safe)-\(sessionID.prefix(8))")
        recorder = SessionRecorder(sessionID: sessionID, label: label, display: display)
    }

    /// Create the session's display if it doesn't exist yet. Any thread.
    public func ensureDisplay() throws {
        guard !display.isRunning else { return }
        func onMain(_ work: () -> Void) { if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) } }
        let waitStart = nowMs()
        stateLock.lock(); let busy = _busy; stateLock.unlock()
        let got = display.reserve(timeout: Self.displayWaitS) {
            stateLock.lock(); _busy = "Waiting for a display"; stateLock.unlock()
            changed()
            log("All \(AgentDisplay.maxDisplays) agent displays are in use; waiting for one")
        }
        guard got else {
            throw ToolError("all \(AgentDisplay.maxDisplays) agent displays are in use by other agents, and none freed up in \(Int(Self.displayWaitS)) s. Wait a minute and try again.")
        }
        if nowMs() - waitStart > 100 {
            stateLock.lock(); _busy = busy; stateLock.unlock()
            changed()
            agentWaitNotes.append("waited \(String(format: "%.0f", (nowMs() - waitStart) / 1000)) s for a free display, since \(AgentDisplay.maxDisplays) other agents were using theirs")
        }
        var failure: Error?
        onMain { do { try self.display.start() } catch { failure = error } }
        if let failure { throw failure }
        guard display.waitUntilOnline() else {
            onMain { self.display.stop() }
            throw ToolError("virtual display never came online")
        }
        onMain {
            self.display.finishStart()
            self.windows.startWatchdog()
        }
        recorder.start()
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
            self.recorder.stop()
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
        recorder.stop()
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
        recorder.note(text, error: error)
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

    /// The window the agent handed to the user, if any.
    public var handoffWindow: AgentWindow? {
        windows.windows.first { $0.handedOff }
    }

    /// The user asked for the handed-off window: bring it onto their screen
    /// (`area`, global points, top-left origin) in front. Off the engine's
    /// queue, so a call that's running doesn't hold it up.
    public func bringHandoffToUser(area: CGRect) {
        guard let w = handoffWindow else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.windows.bringToUser(w.id, area: area)
                self.log("You opened \(w.appName) to take over")
            } catch {
                self.log("Couldn't bring \(w.appName) to you: \(error)", error: true)
            }
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
                recorder.captureSoon()
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
            waitNotes = []
            agentWaitNotes = []
            waitBudget.step()
            if monitored { focusGuard.startMonitor() }
            do {
                var result = try run(tool: tool, args: Args(args))
                if !waitNotes.isEmpty {
                    result.text += "\n[user first] " + waitNotes.map(Self.sentence).joined(separator: " ") + " That's expected: the step ran, don't repeat it."
                    waitNotes = []
                }
                if !agentWaitNotes.isEmpty {
                    result.text += "\n[other agents] " + agentWaitNotes.map(Self.sentence).joined(separator: " ") + " That's expected: the step ran, don't repeat it."
                    agentWaitNotes = []
                }
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
        let outerPriority = priorityNow
        priorityNow = args.string("priority")?.lowercased() == "now"
        defer { priorityNow = outerPriority }
        defer {
            if Self.batchable.contains(tool), tool != "wait", let id = args.int("window_id") {
                lastActionMs[CGWindowID(id)] = nowMs()
            }
            // Still at work in that window: it keeps its app's key a while longer.
            if let id = args.int("window_id") { focusGuard.touchParked(window: CGWindowID(id)) }
        }
        // Opening or borrowing a window is what needs a display.
        if tool == "open_window" || tool == "borrow_window" { try ensureDisplay() }
        return try dispatch(tool: tool, args: args)
    }

    /// Maintenance and test tools (`admin_*`) work only when the app was
    /// started with BCU_ADMIN_TOOLS=1. They can type into and close any
    /// app's windows, so no agent gets them in a normal run.
    public static let adminToolsEnabled = ProcessInfo.processInfo.environment["BCU_ADMIN_TOOLS"] == "1"

    private func dispatch(tool: String, args: Args) throws -> ToolResult {
        if tool.hasPrefix("admin_") && !Self.adminToolsEnabled { throw ToolError("unknown tool \(tool)") }
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
        case "navigate": return try navigate(args)
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
        case "admin_film":
            // Test: film a user window (its pixels and the screen around it)
            // and the menu bar while running `steps` (like batch's actions).
            let user = CGWindowID(try args.requireInt("user_window"))
            guard let info = WindowList.info(user) else { throw ToolError("no window \(user)") }
            let steps = (args.raw["steps"] as? [JSONObject]) ?? []
            var display: CGDirectDisplayID = 0
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(CGPoint(x: info.bounds.midX, y: info.bounds.midY), 1, &display, &count)
            let around = info.bounds.insetBy(dx: -64, dy: -64).intersection(count == 1 ? CGDisplayBounds(display) : info.bounds)
            var tracks = [Film.window("user window", user), Film.screen("user window on screen", around)]
            if let bar = WindowList.all(onScreenOnly: true).first(where: { $0.owner == "Window Server" && $0.title == "Menubar" && $0.bounds.contains(CGPoint(x: info.bounds.midX, y: $0.bounds.midY)) }) {
                tracks.append(Film.window("menu bar", bar.id))
                tracks.append(Film.screen("menu bar on screen", bar.bounds))
            }
            let report = Film.run(tracks, tailMs: args.double("tail_ms") ?? 500) {
                steps.map { step -> String in
                    var a = step
                    let tool = a.removeValue(forKey: "tool") as? String ?? ""
                    let r = (try? run(tool: tool, args: Args(a)))?.text ?? "failed"
                    return "\(tool): \(r.split(separator: "\n").first.map(String.init) ?? "")"
                }.joined(separator: "; ")
            }
            return ToolResult(text: report)
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
        case "admin_screen":
            // Test: what the main display shows.
            let b = CGDisplayBounds(CGMainDisplayID())
            guard let img = BCUCaptureDisplayRect(CGMainDisplayID(), CGRect(origin: .zero, size: b.size)), let png = pngImage(img) else { throw ToolError("capture failed") }
            return ToolResult(text: "main display", images: [png])
        case "admin_raise":
            // Test setup: bring a user window to the front of its app and the app to the front.
            let pid = pid_t(try args.requireInt("pid"))
            let wid = CGWindowID(try args.requireInt("window_id"))
            guard let win = AX.window(pid: pid, id: wid) else { throw ToolError("no window") }
            _ = AX.perform(win, "AXRaise")
            _ = BCUSetFrontProcess(pid, wid, 0x200)
            _ = BCUPostMakeKeyRecords(pid, wid)
            AX.set(AX.app(pid), "AXFocusedWindow", win)
            sleepMs(300)
            return ToolResult(text: "front=\(BCUFrontProcessPID()) keyWindow=\(AX.focusedWindowID(pid).map(String.init) ?? "none")")
        case "admin_discard_window":
            // Test cleanup: close any app's window, answering "Delete" / "Don't Save" if it asks.
            let pid = pid_t(try args.requireInt("pid"))
            let wid = CGWindowID(try args.requireInt("window_id"))
            guard let win = AX.window(pid: pid, id: wid) else { throw ToolError("no window") }
            if let close = AX.element(win, "AXCloseButton") { _ = AX.perform(close, "AXPress") }
            sleepMs(400)
            func press(_ el: AXUIElement, _ depth: Int) -> Bool {
                if depth > 8 { return false }
                if AX.string(el, "AXRole") == "AXButton", ["Delete", "Don’t Save", "Don't Save"].contains(AX.string(el, "AXTitle") ?? "") {
                    return AX.perform(el, "AXPress") == .success
                }
                return AX.children(el).contains { press($0, depth + 1) }
            }
            let pressed = press(win, 0)
            sleepMs(300)
            return ToolResult(text: "\(pressed ? "answered the sheet" : "no sheet"); window \(WindowList.info(wid) == nil ? "closed" : "still open")")
        case "admin_reset_wait_budget":
            waitBudget.reset()
            return ToolResult(text: "reset")
        case "admin_user_sim":
            let also = ((args.raw["also_pids"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber).map { pid_t($0.intValue) } }
            return UserSim.shared.start((args.raw["script"] as? [JSONObject]) ?? [], pid: pid_t(try args.requireInt("pid")),
                                         window: CGWindowID(args.int("window_id") ?? 0), title: args.string("title"), also: also)
        case "admin_chaos":
            return Chaos.shared.start((args.raw["ops"] as? [JSONObject]) ?? [], guard: focusGuard)
        case "admin_chaos_status":
            return Chaos.shared.status()
        case "admin_chaos_stop":
            return Chaos.shared.stop()
        case "admin_guard_events":
            // Test: the guard's recent events, cleared after.
            let events = focusGuard.recentEvents.map(\.summary)
            if args.bool("clear") ?? true { focusGuard.clearEvents() }
            return ToolResult(text: events.joined(separator: "\n"))
        case "admin_user_sim_status":
            return UserSim.shared.status()
        case "admin_user_sim_stop":
            return UserSim.shared.stop()
        case "admin_type_status":
            return TestHarness.shared.typingStatus()
        case "admin_read_text":
            return try TestHarness.read(app: try args.requireString("app"), windows: windows,
                                        windowID: args.int("window_id").map { CGWindowID($0) }, all: args.bool("all") ?? false,
                                        set: args.string("set"))
        default: throw ToolError("unknown tool \(tool)")
        }
    }

    // MARK: Helpers

    /// Tell the previews where this action lands.
    private func point(_ p: CGPoint, _ kind: AgentPointer.Kind = .move) {
        let b = display.bounds
        guard !b.isEmpty else { return }
        func clamp(_ q: CGPoint) -> CGPoint {
            CGPoint(x: min(max(q.x, b.minX), b.maxX - 1), y: min(max(q.y, b.minY), b.maxY - 1))
        }
        var kind = kind
        if case .drag(let to) = kind { kind = .drag(to: clamp(to)) }
        let pointer = AgentPointer(point: clamp(p), kind: kind)
        stateLock.lock()
        if case .drag(let to) = kind { _lastPointer = to } else { _lastPointer = pointer.point }
        stateLock.unlock()
        recorder.pointer(pointer)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.pointerNotification, object: self, userInfo: ["pointer": pointer])
        }
    }

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
        guard BCUFrontProcessPID() == pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        // Not when the app put itself in front because of an agent's step:
        // the guard is putting the user's app back.
        return pid == focusGuard.userFront || !focusGuard.agentCaused(pid)
    }

    /// Run `body` with the window as its app's key window, under the guard.
    /// Keystrokes and pixel clicks go to the app's key window, so the agent's
    /// window is made key for the length of `body` and key goes straight back.
    /// If the user is in that app, this takes key focus from their window for
    /// that moment: their keys and clicks are held and replayed after, so none
    /// of them land in the agent's window, and a still copy of their window
    /// and the menu bar covers the moment their window is drawn inactive.
    /// Typing avoids this altogether where it can (see `typeText`).
    /// Before that, while the user is in the app, it waits for a pause in
    /// their input (unless the step passed `priority: "now"`), and in a batch
    /// the cover stays up across back-to-back steps like this.
    ///
    /// `body` gets a check to call right before it posts anything: it throws
    /// unless the agent's window is still the app's key window and the user
    /// hasn't switched to the app since, so input never goes anywhere else.
    private func keyed<T>(_ w: AgentWindow, cause: String, _ body: (_ check: () throws -> Void) throws -> T) throws -> T {
        if paused { throw ToolError("paused by the user") }
        if userInControl { throw ToolError("the user took over your display") }
        if let c = cover, !(c.pid == w.pid && userIsIn(w.pid) && nowMs() - c.lastUsedMs < Self.coverGapMs
                             && nowMs() - c.openedMs < Self.coverMaxMs) {
            closeCover()
        }
        if cover == nil && userIsIn(w.pid) && !priorityNow {
            try awaitUser(w, cause: cause)
        }
        // Another agent mid-task in this app goes first. Checked again under
        // the input lock: it may have started a step while this one waited.
        let turnStart = nowMs()
        while true {
            if !userIsIn(w.pid) { try awaitAgentTurn(w, cause: cause, since: turnStart) }
            Self.inputLock.lock()
            if userIsIn(w.pid) || leaseHolder(w.pid, window: w.id) == nil || nowMs() - turnStart > Self.agentWaitMaxMs { break }
            Self.inputLock.unlock()
        }
        defer { Self.inputLock.unlock() }
        focusGuard.beginAction(pid: w.pid, cause: cause)
        windows.noteBefore(pid: w.pid)
        defer { focusGuard.endAction(pid: w.pid) }
        let shared = userIsIn(w.pid)
        if cover == nil && shared { openCover(w, cause: cause) } else if cover != nil { UserSim.shared.coverUsed(cause) }
        defer {
            if batching { cover?.lastUsedMs = nowMs() } else { closeCover() }
        }
        // From here until key is back, the guard holds keys typed into this
        // app and clicks on it, even if the user wasn't in it.
        focusGuard.beginSwap(w.pid)
        defer { focusGuard.endSwap(w.pid) }
        // Key must be the user's going in, or the swap wouldn't give it back.
        let userWindow = shared ? (cover?.userWindow ?? focusGuard.userWindow(of: w.pid)) : nil
        if shared { focusGuard.reclaimKey(w.pid, prefer: userWindow) }
        let scope: KeyScope
        do {
            scope = try KeyScope.enter(pid: w.pid, window: w.id, giveBackTo: userWindow)
        } catch {
            focusGuard.scheduleReclaim(w.pid)
            throw error
        }
        // Key is this window's now, whoever had it parked before; other
        // agents wait while this step runs too.
        focusGuard.park(w.pid, window: w.id, owner: sessionID)
        defer { handBack(scope, w) }
        let wasFront = BCUFrontProcessPID() == w.pid
        let check = { [self] in
            let key = AX.focusedWindowID(w.pid)
            if let key, key != w.id {
                throw ToolError("\(w.appName)'s key window changed to window \(key) (\(FocusGuard.onAgentDisplay(key) ? "another agent window" : "the user's")), so nothing more was sent")
            }
            if key == nil {
                throw ToolError("\(w.appName) has no key window now (or isn't answering), so nothing more was sent")
            }
            if !wasFront && BCUFrontProcessPID() == w.pid && !focusGuard.agentCaused(w.pid) {
                throw ToolError("the user switched to \(w.appName), so nothing more was sent")
            }
        }
        let result = try body(check)
        // Let focus moves (Tab, a click) land before noting the focused field.
        sleepMs(30)
        rememberFocusedText(in: w)
        return result
    }

    /// Give key back after a swap, and while the user is in the app, make
    /// sure it's on their window before their held input goes on: retry for
    /// up to a second (the guard holds their keys until it is).
    private func handBack(_ scope: KeyScope, _ w: AgentWindow) {
        let t0 = nowMs()
        // The user isn't in the app: the window keeps key until the agent's
        // next step (see `FocusGuard.park`).
        if !userIsIn(w.pid) && scope.keepKey() {
            focusGuard.park(w.pid, window: w.id, owner: sessionID)
            return
        }
        focusGuard.forgetParked(w.pid)
        let confirmed = scope.exit()
        guard userIsIn(w.pid) else {
            if !confirmed { focusGuard.scheduleReclaim(w.pid) }
            return
        }
        var safe = false
        while true {
            focusGuard.reclaimKey(w.pid, prefer: scope.previous)
            safe = focusGuard.keySafe(w.pid)
            if safe || nowMs() - t0 > 1000 { break }
            sleepMs(50)
        }
        if !safe {
            Log.info("swap: COULD NOT give key back in \(w.appName) after \(Int(nowMs() - t0)) ms (key is \(AX.focusedWindowID(w.pid).map(String.init) ?? "unknown")); the user's keys stay held")
        } else if !confirmed {
            Log.info("swap: key back in \(w.appName) after a retry (\(Int(nowMs() - t0)) ms)")
        }
    }

    private struct SwapCover {
        let pid: pid_t
        let freeze: ScreenFreeze?
        let hold: Int
        /// The user's window in the app, which gets key back.
        let userWindow: CGWindowID?
        let openedMs: Double
        var lastUsedMs: Double
    }

    /// A batch keeps the cover up for the next step only if it starts this
    /// soon, and never longer than this in all, since the user's input is
    /// held the whole time. Typing ends a swap after `typeChunkMs`, so a
    /// step started inside `coverMaxMs` ends well inside the guard's own
    /// limit (`FocusGuard.maxHoldMs`).
    private static let coverGapMs = 500.0
    private static let coverMaxMs = 1000.0
    private static let inFlightMs = 60.0
    /// Captures of the user's window before going without a copy, when
    /// they keep typing through each one.
    private static let captureTries = 3
    /// Keystroke typing goes in swaps of at most this many characters and this long.
    private static let typeChunk = 16
    private static let typeChunkMs = 400.0

    /// Hold the user's input and cover their window, which is about to be
    /// drawn inactive for a moment.
    private func openCover(_ w: AgentWindow, cause: String) {
        // Capture the copy before holding the user's input, not after: a
        // capture can keep WindowServer busy for 100 ms or more on a busy
        // machine, and their input shouldn't wait on that. If they type
        // during the capture, the copy is out of date, so capture again
        // (or go without one).
        var hold: Int?
        var freeze: ScreenFreeze?
        var userWindow: CGWindowID?
        for _ in 0..<Self.captureTries {
            // A key the user pressed just now is still being drawn: let it
            // land first, or the copy would never match their window again
            // and stay up until it times out.
            let sinceInput = nowMs() - focusGuard.activity.snapshot.lastInputMs
            if sinceInput < Self.inFlightMs { sleepMs(Self.inFlightMs - sinceInput) }
            focusGuard.reclaimKey(w.pid)
            guard let key = AX.focusedWindowID(w.pid), key != w.id, !FocusGuard.onAgentDisplay(key) else { break }
            userWindow = key
            let start = nowMs()
            let shots = ScreenFreeze.capture(userWindow: key)
            let h = focusGuard.beginHold()
            if focusGuard.activity.snapshot.lastInputMs < start {
                hold = h
                if let shots { freeze = ScreenFreeze.show(shots) }
                break
            }
            focusGuard.endHold(h)
        }
        let held = hold ?? focusGuard.beginHold()
        cover = SwapCover(pid: w.pid, freeze: freeze, hold: held, userWindow: userWindow ?? focusGuard.userWindow(of: w.pid),
                          openedMs: nowMs(), lastUsedMs: nowMs())
        UserSim.shared.coverOpened(cause)
    }

    /// Let the user's input go on (the guard replays it once key is theirs),
    /// then take the copy off once their window looks as before.
    private func closeCover() {
        guard let c = cover else { return }
        cover = nil
        focusGuard.endHold(c.hold)
        c.freeze?.end()
        UserSim.shared.coverClosed()
    }

    /// When another agent's window has key in this app and that agent did
    /// something there within `agentLeaseMs`, it's probably mid-way through
    /// a form: taking key now would blur the field it's in. Wait for it to
    /// go quiet, up to `agentWaitMaxMs`. The user never waits for this.
    private func awaitAgentTurn(_ w: AgentWindow, cause: String, since: Double) throws {
        try awaitAgentTurn(pid: w.pid, window: w.id, appName: w.appName, cause: cause, since: since)
    }

    /// Another agent's window that has key in `pid` and that agent did
    /// something there within `agentLeaseMs`.
    private func leaseHolder(_ pid: pid_t, window: CGWindowID?) -> FocusGuard.ParkedKey? {
        guard let p = focusGuard.parkedKey(pid), p.owner != sessionID, p.window != window,
              nowMs() - p.lastUsedMs < Self.agentLeaseMs, AX.focusedWindowID(pid) == p.window else { return nil }
        return p
    }

    private func awaitAgentTurn(pid: pid_t, window: CGWindowID?, appName: String, cause: String, since start: Double = nowMs()) throws {
        var waited = false
        stateLock.lock(); let busy = _busy; stateLock.unlock()
        defer {
            if waited {
                stateLock.lock(); _busy = busy; stateLock.unlock()
                changed()
            }
        }
        while let p = leaseHolder(pid, window: window) {
            if paused { throw ToolError("paused by the user") }
            if userInControl { throw ToolError("the user took over your display") }
            if userIsIn(pid) { break }
            if nowMs() - start > Self.agentWaitMaxMs {
                agentWaitNotes.append("waited \(Int(Self.agentWaitMaxMs / 1000)) s for another agent working in \(appName), then went ahead with \(cause)")
                Log.info("lease: \(label) waited \(Int(nowMs() - start)) ms for window \(p.window) in \(appName), then took key anyway")
                return
            }
            if !waited {
                waited = true
                stateLock.lock(); _busy = "Waiting for another agent"; stateLock.unlock()
                changed()
            }
            sleepMs(100)
        }
        if waited {
            let s = (nowMs() - start) / 1000
            agentWaitNotes.removeAll { $0.contains("for another agent") }
            agentWaitNotes.append("waited \(String(format: "%.1f", s)) s for another agent to finish in \(appName) before \(cause)")
            Log.info("lease: \(label) waited \(Int(nowMs() - start)) ms for another agent in \(appName) before \(cause)")
        }
    }

    /// Wait for a moment the user won't notice their window freezing, and
    /// note it for the step's result. Throws if they paused the agent or
    /// took over meanwhile, or if at the cap they're still mid something
    /// moving focus would break (a menu open, a button or key held).
    private func awaitUser(_ w: AgentWindow, cause: String) throws {
        try awaitUser(pid: w.pid, appName: w.appName, cause: cause, anywhere: false)
    }

    /// `anywhere`: the step may bring its app to the front, which breaks a
    /// drag or a menu in whatever app the user is in, so wait out those
    /// (only those) wherever they are. Otherwise the step only moves focus
    /// inside `pid`, the app the user is in: the full pause rules.
    private func awaitUser(pid: pid_t, appName: String, cause: String, anywhere: Bool) throws {
        let caps = waitBudget.caps
        let startMs = nowMs()
        stateLock.lock(); let busy = _busy; stateLock.unlock()
        var shown = false
        let willWait = {
            shown = true
            self.stateLock.lock(); self._busy = "Waiting for you to pause"; self.stateLock.unlock()
            self.changed()
        }
        let stop = { self.paused || self.userInControl }
        let r = anywhere
            ? QuietWait.waitAnywhere(focusGuard.activity, hardMs: caps.hardMs, stop: stop, willWait: willWait)
            : QuietWait.wait(focusGuard.activity, pid: pid, softMs: caps.softMs, hardMs: caps.hardMs, stop: stop, willWait: willWait)
        waitBudget.add(r.waitedMs)
        if shown {
            stateLock.lock(); _busy = busy; stateLock.unlock()
            changed()
        }
        if paused { throw ToolError("paused by the user") }
        if userInControl { throw ToolError("the user took over your display") }
        let secs = String(format: "%.1f", r.waitedMs / 1000)
        let where_ = anywhere ? "" : " in \(appName)"
        // Opening a window can bring its app to the front, closing whatever menu
        // is open and ending any drag, wherever the user is.
        let effect = anywhere ? "\(cause) could bring \(appName) to the front and" : cause
        if r.outcome == .menu {
            let note = "waited \(secs) s\(where_) before \(cause), but the user has a menu open"
            UserSim.shared.waited(fromMs: startMs, note)
            Log.info("defer: \(note); failed the step")
            throw ToolError("the user has a menu open\(where_), and \(effect) would close it, so nothing was done. Wait a few seconds and retry.")
        }
        if r.outcome == .held {
            let note = "waited \(secs) s\(where_) before \(cause), but the user is holding a mouse button or key"
            UserSim.shared.waited(fromMs: startMs, note)
            Log.info("defer: \(note); failed the step")
            let browser = BrowserAutomation.isScriptableChromium(NSRunningApplication(processIdentifier: pid)?.bundleURL ?? URL(fileURLWithPath: "/"))
            throw ToolError("the user is holding a mouse button or key\(where_) (dragging, say), and \(effect) would interrupt it, so nothing was done. Wait a few seconds and retry\(browser && !anywhere ? ", or use navigate to load a URL without keys" : "").")
        }
        guard r.waitedMs >= 20 else { return }
        var note = "waited \(secs) s for \(r.reason ?? "the user to pause")\(anywhere ? "" : " in \(appName)") before \(cause)"
        switch r.outcome {
        case .quiet, .menu, .held, .stopped: break
        case .gap: note += ", then went in a short gap in their input"
        case .cap: note += ", then went anyway (their input was held and replayed)"
        }
        waitNotes.append(note)
        UserSim.shared.waited(fromMs: startMs, note)
        Log.info("defer: \(note) (caps \(Int(caps.softMs))/\(Int(caps.hardMs)) ms; \(Int(waitBudget.share * 100))% of recent working time spent waiting)")
    }

    private static func sentence(_ s: String) -> String {
        (s.prefix(1).uppercased() + s.dropFirst()) + "."
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
        // A new window takes its app's key: let another agent at work in
        // that app finish its step first.
        if !shared, let running = try windows.resolveApp(app).running {
            try awaitAgentTurn(pid: running.processIdentifier, window: nil, appName: running.localizedName ?? app, cause: "opening a window")
        }
        // Opening a window moves focus: never mid a drag, a menu or a held key.
        // In the app the user is in, the new window takes key from theirs
        // (the full pause rules); elsewhere it may bring its app to the front
        // (Chromium does, launching does), which breaks those in any app.
        if !priorityNow {
            let target = try windows.resolveApp(app)
            try awaitUser(pid: target.running?.processIdentifier ?? 0, appName: target.name, cause: "opening a window", anywhere: !shared)
        }
        let hold = shared ? InputHold(focusGuard) : nil
        defer { _ = hold?.end() }
        let result = try windows.open(app: app, placement: WindowManager.Placement(name: args.string("placement")), trigger: args.string("trigger"), hold: hold)
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
            focusedText[id] = nil
            return ToolResult(text: "window \(id) is already closed")
        }
        let text = try windows.release(id, keepOpen: args.bool("keep_open") ?? false)
        snapshots[id] = nil
        focusedText[id] = nil
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
        if args.bool("screenshot") ?? true, let raw = try? Capture.window(w.id) {
            recorder.windowShot(w.id, raw)
            if let png = pngImage(Capture.inPoints(raw, id: w.id, display: display.bounds)) { images.append(png) }
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
                                                 "scroll", "drag", "press_menu_item", "navigate", "wait"]

    /// Steps that may take key focus in their app (see `keyed`).
    private static func mayTakeKey(_ tool: String, _ a: Args) -> Bool {
        switch tool {
        case "press_key", "drag", "press_menu_item": return true
        case "click": return a.int("element") == nil
        case "type_text": return (a.string("text") ?? "").contains { $0 == "\n" || $0 == "\r" || $0 == "\t" }
        default: return false
        }
    }

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
        func argsOf(_ i: Int) -> JSONObject {
            var a = steps[i]
            a["tool"] = nil
            if a["window_id"] == nil, let d = defaultWindow { a["window_id"] = d }
            if a["priority"] == nil, let p = args.string("priority") { a["priority"] = p }
            return a
        }
        batching = true
        defer { closeCover(); batching = false }
        var waitedNotes = 0
        for (i, step) in steps.enumerated() {
            let tool = step["tool"] as! String
            let stepArgs = argsOf(i)
            if let wid = Args(stepArgs).int("window_id") { lastWindow = wid }
            defer {
                // Keep the user's window covered only into a next step that
                // takes key focus too.
                if i + 1 >= steps.count || !Self.mayTakeKey(steps[i + 1]["tool"] as? String ?? "", Args(argsOf(i + 1))) { closeCover() }
            }
            if tool == "wait" {
                let ms = min(max(Args(stepArgs).double("ms") ?? 500, 0), 5000)
                sleepMs(ms)
                lines.append("\(i + 1). wait: \(Int(ms)) ms")
                continue
            }
            do {
                let r = try run(tool: tool, args: Args(stepArgs))
                let first = r.text.split(separator: "\n").first.map(String.init) ?? "done"
                // History gets each step, not just the whole batch at the end.
                recorder.note("\(tool): \(first)", error: false)
                recorder.captureSoon()
                var line = "\(i + 1). \(tool): \(first)"
                if !waitNotes.isEmpty { line += " (\(waitNotes.joined(separator: "; ")))"; waitedNotes += waitNotes.count; waitNotes = [] }
                lines.append(line)
            } catch {
                lines.append("\(i + 1). \(tool) FAILED: \(error)")
                waitNotes = []
                if i + 2 == steps.count { lines.append("Stopped; action \(i + 2) didn't run.") }
                if i + 2 < steps.count { lines.append("Stopped; actions \(i + 2)–\(steps.count) didn't run.") }
                failed = true
                break
            }
        }
        if waitedNotes > 0 {
            lines.append("[user first] Steps that waited for the user to pause ran then; that's expected, don't repeat them.")
        }
        closeCover()
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
            let raw = try Capture.window(w.id)
            recorder.windowShot(w.id, raw)
            let img = Capture.inPoints(raw, id: w.id, display: display.bounds)
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
            point(n.frame.center, .click)
            if button == .left && count == 1 && n.actions.contains("AXPress") {
                let err = guarded(w, cause: "pressing an element") { AX.perform(n.element, "AXPress") }
                if err == .success {
                    if Self.textRoles.contains(n.role) { focusedText[w.id] = TextFocus(element: n.element, range: nil, value: AX.string(n.element, "AXValue") ?? "") }
                    return ToolResult(text: "Pressed element \(n.index) (\(n.role)) through accessibility.")
                }
            }
            if button == .right && n.actions.contains("AXShowMenu") {
                let err = guarded(w, cause: "opening a context menu") { AX.perform(n.element, "AXShowMenu") }
                if err == .success { return ToolResult(text: "Opened the context menu of element \(n.index). Call get_window_state to see it.") }
            }
            let p = n.frame.center
            try keyed(w, cause: "clicking") { check in try Input.click(pid: w.pid, windowID: w.id, at: p, button: button, count: count, check: check) }
            return ToolResult(text: "Clicked element \(n.index) at its center.")
        }
        let p = try globalPoint(args, window: ax)
        point(p, .click)
        try keyed(w, cause: "clicking") { check in try Input.click(pid: w.pid, windowID: w.id, at: p, button: button, count: count, check: check) }
        return ToolResult(text: "Clicked at (\(Int(args.double("x") ?? 0)), \(Int(args.double("y") ?? 0))).")
    }

    private func setValue(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let n = try node(args, window: w)
        let value = try args.requireString("value")
        point(n.frame.center)
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
        point(n.frame.center, .click)
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
        if let n = target { point(n.frame.center) }

        // The user is in this app, so keystrokes would take key focus from
        // their window. Write the text through accessibility instead.
        if userIsIn(w.pid), AX.focusedWindowID(w.pid) != w.id {
            return try typeShared(w, text: text, target: target)
        }

        // Accessibility insertion first: no keyboard focus involved.
        if let n = target, !text.contains("\n"), !text.contains("\t"), AX.isSettable(n.element, "AXSelectedText") {
            let before = AX.string(n.element, "AXValue") ?? ""
            let err = guarded(w, cause: "typing") { () -> AXError in
                AX.set(n.element, "AXFocused", kCFBooleanTrue)
                return AX.set(n.element, "AXSelectedText", text as CFString)
            }
            if err == .success {
                // It changed: it took the text, maybe its own way (a mask, a
                // length limit). Typing it again would put it in twice.
                _ = waitForValue(n.element, ms: 300) { $0 != before }
                let after = AX.string(n.element, "AXValue") ?? ""
                if after != before {
                    if after.contains(text) { return ToolResult(text: "Inserted the text into element \(n.index) through accessibility.") }
                    return ToolResult(text: "Inserted the text into element \(n.index) through accessibility; the field changed it and now reads \"\(after.prefix(200))\".")
                }
            }
        }
        if let n = target {
            guarded(w, cause: "focusing") { _ = AX.set(n.element, "AXFocused", kCFBooleanTrue) }
            sleepMs(50)
        }
        try typeKeys(w, text)
        return ToolResult(text: "Typed \(text.count) characters with keystrokes.")
    }

    /// Type with keystrokes, in short swaps (each holds the user's input if
    /// they're in the app, so keep that short). Before every character the
    /// agent's window must still be key; if the user switched to the app
    /// partway, it stops rather than guess where the rest would go.
    private func typeKeys(_ w: AgentWindow, _ text: String) throws {
        let total = text.count
        let startedIn = userIsIn(w.pid)
        var typed = 0
        var rest = Substring(text)
        func stopped(_ why: String) -> ToolError {
            let more = typed == 0 ? "Nothing was typed." : "Typed \(typed) of \(total) characters (\"\(text.prefix(typed).suffix(40))\"), nothing after that."
            return ToolError("stopped typing: \(why). \(more) Read the window, then type what's missing.")
        }
        while !rest.isEmpty {
            if !startedIn && userIsIn(w.pid) { throw stopped("the user switched to \(w.appName)") }
            let piece = String(rest.prefix(Self.typeChunk))
            var sent = 0
            do {
                try keyed(w, cause: "typing") { check in
                    let start = nowMs()
                    let n = try Input.typeText(pid: w.pid, piece, windowID: w.id) { i in
                        sent = i
                        // Keep each swap short: the user's input may be held meanwhile.
                        if i > 0 && nowMs() - start > Self.typeChunkMs { return false }
                        try check()
                        return true
                    }
                    sent = n
                }
            } catch {
                typed += sent
                throw stopped("\(error)")
            }
            typed += sent
            rest = rest.dropFirst(sent)
            if !rest.isEmpty { closeCover(); sleepMs(40) }
        }
    }

    /// Typing while the user is in the same app. The text goes in through
    /// accessibility, which doesn't need key focus. Keys, and so a moment of
    /// key focus, only for Return and Tab and for fields that ignore
    /// accessibility writes.
    private func typeShared(_ w: AgentWindow, text: String, target: AXNode?) throws -> ToolResult {
        let element = target?.element ?? focusedTextElement(in: w)
        // Runs of text, with each Return or Tab on its own.
        var parts: [String] = []
        var run = ""
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" {
                if !run.isEmpty { parts.append(run); run = "" }
                parts.append(String(ch))
            } else {
                run.append(ch)
            }
        }
        if !run.isEmpty { parts.append(run) }
        var viaAX = 0, viaKeys = 0
        var focused = target == nil
        var changedTo: String?
        for part in parts {
            let isKey = part == "\n" || part == "\r" || part == "\t"
            if !isKey, let el = element {
                switch guarded(w, cause: "typing", { axInsert(el, part, in: w) }) {
                case .exact:
                    viaAX += part.count
                    changedTo = nil
                    continue
                case .changed(let now):
                    // The field took it its own way: don't type it again.
                    viaAX += part.count
                    changedTo = now
                    continue
                case .failed:
                    break
                }
            }
            // Keys go to the window's focused element: make that the target first.
            if !focused, let el = element {
                guarded(w, cause: "focusing") { _ = AX.set(el, "AXFocused", kCFBooleanTrue) }
                sleepMs(50)
                focused = true
            }
            try typeKeys(w, part)
            viaKeys += part.count
        }
        let into = target.map { " into element \($0.index)" } ?? ""
        let changed = changedTo.map { " The field changed the text as it went in; it now reads \"\($0.prefix(200))\"." } ?? ""
        if viaKeys == 0 {
            return ToolResult(text: "Typed \(viaAX) characters\(into) through accessibility (the user is using \(w.appName), so no keystrokes).\(changed)")
        }
        if viaAX == 0 {
            return ToolResult(text: "Typed \(viaKeys) characters\(into) with keystrokes.")
        }
        return ToolResult(text: "Typed \(viaAX) characters\(into) through accessibility and \(viaKeys) (Return/Tab) with keystrokes.\(changed)")
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The text element with focus in the agent's window, found without making
    /// the window key: the element the window's own tree marks focused (web
    /// content does), else the one that had focus when the window was last
    /// key (AppKit marks nothing focused in a window that isn't key). Nil when
    /// something other than a text field has focus: then keys decide.
    private func focusedTextElement(in w: AgentWindow) -> AXUIElement? {
        if let snap = snapshots[w.id],
           let n = snap.nodes.values.first(where: { AX.bool($0.element, "AXFocused") == true && $0.role != "AXWebArea" }) {
            return Self.textRoles.contains(n.role) ? n.element : nil
        }
        if let f = focusedText[w.id], AX.string(f.element, "AXRole") != nil { return f.element }
        return nil
    }

    /// Note the window's focused text element, its selection and value,
    /// while the window is key. Something else focused: forget the field.
    private func rememberFocusedText(in w: AgentWindow) {
        guard let el = AX.element(AX.app(w.pid), "AXFocusedUIElement"),
              let win = AX.element(el, "AXWindow"), AX.windowID(win) == w.id else { return }
        guard Self.textRoles.contains(AX.string(el, "AXRole") ?? "") else { focusedText[w.id] = nil; return }
        focusedText[w.id] = TextFocus(element: el, range: AX.range(el, "AXSelectedTextRange"), value: AX.string(el, "AXValue") ?? "")
    }

    private enum Insert {
        /// The field reads exactly as typing would have left it.
        case exact
        /// It changed, but not to that (a mask, a length limit, autocomplete):
        /// the text went in its own way, so it mustn't be typed again.
        case changed(String)
        /// Nothing changed: type it.
        case failed
    }

    /// Insert `text` at the element's selection through accessibility, and
    /// check that the field reads as typing would have left it.
    /// Single-line fields get their value rewritten with the text spliced in
    /// at the selection: web fields in a window without key focus take only
    /// that, and Chromium's address bar inserts AXSelectedText at an older
    /// selection and then ignores Return. Text areas, which can hold
    /// formatting, take AXSelectedText (AppKit text views do); a rewrite only
    /// when they're empty.
    private func axInsert(_ el: AXUIElement, _ text: String, in w: AgentWindow) -> Insert {
        let role = AX.string(el, "AXRole") ?? ""
        guard Self.textRoles.contains(role), AX.string(el, "AXSubrole") != "AXSecureTextField" else { return .failed }
        let before = AX.string(el, "AXValue") ?? ""
        let old = before as NSString
        func usable(_ s: CFRange) -> Bool { s.location >= 0 && s.length >= 0 && s.location + s.length <= old.length }
        // At the selection: live if the field has focus, else as it was when
        // the window was last key (if the field hasn't changed since), else
        // at the end, where clicking into it would put the caret.
        var r = NSRange(location: old.length, length: 0)
        if AX.bool(el, "AXFocused") == true, let s = AX.range(el, "AXSelectedTextRange"), usable(s) {
            r = NSRange(location: s.location, length: s.length)
        } else if let f = focusedText[w.id], CFEqual(f.element, el), f.value == before, let s = f.range, usable(s) {
            r = NSRange(location: s.location, length: s.length)
        }
        let expected = old.replacingCharacters(in: r, with: text)
        let caret = r.location + (text as NSString).length
        func outcome() -> Insert {
            // Whatever it reads now, the text is in: remember it as typed.
            let now = AX.string(el, "AXValue") ?? ""
            if now == expected {
                focusedText[w.id] = TextFocus(element: el, range: CFRange(location: caret, length: 0), value: now)
                return .exact
            }
            if now != before {
                focusedText[w.id] = TextFocus(element: el, range: nil, value: now)
                return .changed(now)
            }
            return .failed
        }
        func rewrite() -> Insert {
            guard AX.isSettable(el, "AXValue"), AX.set(el, "AXValue", expected as CFString) == .success else { return .failed }
            _ = waitForValue(el, ms: 300) { $0 == expected }
            let result = outcome()
            if case .exact = result {
                var c = CFRange(location: caret, length: 0)
                if let v = AXValueCreate(.cfRange, &c) { AX.set(el, "AXSelectedTextRange", v) }
            }
            return result
        }
        if role != "AXTextArea" { return rewrite() }
        if AX.isSettable(el, "AXSelectedText"), AX.set(el, "AXSelectedText", text as CFString) == .success {
            _ = waitForValue(el, ms: 300) { $0 == expected }
            let result = outcome()
            if case .failed = result {} else { return result }
        }
        // Didn't go in (and nothing changed): an empty area can take a rewrite.
        return before.isEmpty ? rewrite() : .failed
    }

    private func waitForValue(_ el: AXUIElement, ms: Double, _ ok: (String) -> Bool) -> Bool {
        let deadline = nowMs() + ms
        while true {
            if ok(AX.string(el, "AXValue") ?? "") { return true }
            if nowMs() >= deadline { return false }
            sleepMs(10)
        }
    }

    private func pressKey(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        let key = try args.requireString("key")
        let mods = args.strings("modifiers") ?? []
        try keyed(w, cause: "pressing \((mods + [key]).joined(separator: "+"))") { check in
            try check()
            try Input.pressKey(pid: w.pid, key: key, modifiers: mods, windowID: w.id)
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
        point(p)
        try guarded(w, cause: "scrolling") { try Input.scroll(pid: w.pid, windowID: w.id, at: p, dx: dx, dy: dy) }
        return ToolResult(text: "Scrolled dx=\(dx) dy=\(dy).")
    }

    private func drag(_ args: Args) throws -> ToolResult {
        let (w, ax) = try agentWindow(args)
        guard let f = AX.frame(ax),
              let fx = args.double("from_x"), let fy = args.double("from_y"),
              let tx = args.double("to_x"), let ty = args.double("to_y") else { throw ToolError("give from_x, from_y, to_x, to_y") }
        let from = CGPoint(x: f.minX + fx, y: f.minY + fy), to = CGPoint(x: f.minX + tx, y: f.minY + ty)
        point(from, .drag(to: to))
        try keyed(w, cause: "dragging") { check in
            try check()
            try Input.drag(pid: w.pid, windowID: w.id, from: from, to: to)
        }
        return ToolResult(text: "Dragged from (\(Int(fx)),\(Int(fy))) to (\(Int(tx)),\(Int(ty))).")
    }

    /// Load a URL in one of the agent's Chromium windows through AppleScript:
    /// no keystrokes, so no key swap and no waiting for a pause in the user's
    /// input, only for a drag, a held key or an open menu to end.
    private func navigate(_ args: Args) throws -> ToolResult {
        let (w, _) = try agentWindow(args)
        guard let url = args.string("url")?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { throw ToolError("give url") }
        guard let app = NSRunningApplication(processIdentifier: w.pid), let bundleURL = app.bundleURL, let bundleID = app.bundleIdentifier,
              BrowserAutomation.isScriptableChromium(bundleURL) else {
            throw ToolError("navigate works in Chromium browsers only. In \(w.appName), click the address bar, type_text the URL and \"\\n\".")
        }
        switch BrowserAutomation.permission(bundleID) {
        case .allowed: break
        case .denied:
            throw ToolError("the user hasn't allowed this app to control \(w.appName) (System Settings > Privacy & Security > Automation). Click the address bar and type_text the URL and \"\\n\" instead.")
        case .notAsked:
            BrowserAutomation.request(bundleID) { _ in }
            throw ToolError("macOS is asking the user whether this app may control \(w.appName). Retry once they've answered, or click the address bar and type_text the URL and \"\\n\".")
        }
        guard let frame = WindowList.info(w.id)?.bounds else { throw ToolError("window \(w.id) is gone") }
        // AppleScript knows the browser's windows by its own ids; find this
        // one by its frame, which is the same in both.
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let b = "{\(Int(frame.minX.rounded())), \(Int(frame.minY.rounded())), \(Int(frame.maxX.rounded())), \(Int(frame.maxY.rounded()))}"
        // Two of the browser's windows can share a frame (the cascade repeats),
        // and then nothing tells them apart: load in neither rather than
        // maybe in another task's window.
        let script = """
        with timeout of 5 seconds
        tell application id \(quoted(bundleID))
        set found to {}
        repeat with w in windows
        if bounds of w is \(b) then set end of found to id of w
        end repeat
        if (count of found) is 0 then error "no window with bounds \(b)"
        if (count of found) > 1 then error "more than one window with bounds \(b)"
        set URL of active tab of window id (item 1 of found) to \(quoted(url))
        end tell
        end timeout
        """
        // Chromium shows the window it loads a URL in: it can make it key and
        // bring the app to the front. That would end a drag or close a menu
        // in whatever app the user is in, so wait those out (only those).
        if !priorityNow {
            try awaitUser(pid: w.pid, appName: w.appName, cause: "loading a URL", anywhere: true)
        }
        // Run it as an agent action so the guard puts the user's app straight
        // back, and if the user is in the browser, give key back to their window.
        let shared = userIsIn(w.pid)
        let userWindow = shared ? focusGuard.userWindow(of: w.pid) : nil
        let loaded = guarded(w, cause: "loading a URL") { () -> Bool in
            // Until key is back on the user's window, the guard holds what
            // they type into the browser and their clicks on it, then replays
            // them, so none of it lands in the agent's page.
            focusGuard.beginSwap(w.pid)
            defer { focusGuard.endSwap(w.pid) }
            let ok = WindowManager.runAppleScript(script)
            if shared { _ = focusGuard.reclaimKey(w.pid, prefer: userWindow) }
            return ok
        }
        if shared { focusGuard.scheduleReclaim(w.pid) }
        guard loaded else {
            throw ToolError("\(w.appName) didn't take the URL. Click the address bar, type_text the URL and \"\\n\".")
        }
        return ToolResult(text: "Loading \(url) in window \(w.id). Next: get_window_state window_id=\(w.id) (it waits for the page to settle).")
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
        let err = try keyed(w, cause: "choosing \(path.joined(separator: " > "))") { check -> AXError in
            try check()
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
        return ToolResult(text: "The user was notified with your reason; the window comes onto their screen when they open it. Stop and wait for the user; call take_back when they say they're done.")
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

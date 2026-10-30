import AppKit
import CoreGraphics
import CPrivate

public struct GuardEvent {
    public let time: Date
    public let summary: String
}

/// Keeps the user's focus, keystrokes and cursor theirs.
///
/// - Cursor fence: mouse moves that would land on the agent display are pulled
///   back in the event tap, and a watcher thread checks the cursor every 4 ms
///   and brings it back from anything that got past the tap.
/// - Keystroke hold: if an app the agent is acting on makes itself frontmost,
///   the user's keystrokes are held, the user's app is put back in front, and
///   the keys are replayed into it. Nothing typed lands in the agent's window.
/// - Activation watch: the same restore runs when such an activation is seen
///   even without typing.
/// One guard for every agent display: it fences the cursor off all of them
/// and watches the front app for every session.
public final class FocusGuard {
    public var onEvent: ((GuardEvent) -> Void)?

    private let lock = NSLock()
    /// strict: the user is driving the app from the expanded view, so their
    /// clicks and keys (which land in this app's panel) never explain an activation.
    private var taints: [pid_t: (until: Double, cause: String, strict: Bool)] = [:]
    private var userFrontPid: pid_t = 0
    private var userFrontWindow: CGWindowID?
    private var lastUserMouseDownMs = 0.0
    private var lastUserSwitchKeyMs = 0.0
    private var lastUserKeyMs = 0.0
    private var holding = false
    private var held: [CGEvent] = []
    /// Nesting count of key-window swaps in progress (see `beginHold`).
    private var swapHolds = 0
    /// Replaying held events; anything new queues behind them to keep order.
    private var draining = false
    private var restoring = false
    private var tap: CFMachPort?
    private var lastEscapeLogMs = 0.0
    private var lastTapDisabledLogMs = 0.0
    private let restoreQueue = DispatchQueue(label: "bcu.guard.restore")
    private var events: [GuardEvent] = []

    static let replayMarker: Int64 = 0x4243_5552
    fileprivate static weak var shared: FocusGuard?

    public init() {
    }

    public var recentEvents: [GuardEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func clearEvents() {
        lock.lock(); events.removeAll(); lock.unlock()
    }

    /// Main thread. Needs Accessibility for the event tap.
    public func start() {
        FocusGuard.shared = self
        // WindowServer's view of the front app; NSWorkspace's can be stale at launch.
        let front = BCUFrontProcessPID()
        if front != 0 { noteUserFront(front) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        }
        installTap()
    }

    public var tapInstalled: Bool { tap != nil }

    public func installTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel, .tabletPointer,
                                    .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: guardTapCallback, userInfo: nil) else {
            Log.info("guard: event tap failed (Accessibility permission missing?)")
            return
        }
        tap = port
        // Its own thread: an active HID tap delays every mouse move on the
        // system until its callback returns, so it must never wait on the
        // main thread (UI, accessibility calls into slow apps).
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "bcu.guard.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        Log.info("guard: event tap installed")
    }

    // MARK: Cursor watch

    /// Check the cursor every 4 ms on its own thread and move it off the agent
    /// display whatever put it there: the tap not installed yet, the tap
    /// disabled by macOS, displays being rearranged, or another app warping it.
    public func startCursorWatch() {
        let thread = Thread { [weak self] in
            while let s = self {
                // Every 4 ms near the agent display, every 16 ms elsewhere: a
                // cursor far away can't reach it between checks except by a
                // warp, which this still undoes within 16 ms.
                let near = s.checkCursor()
                usleep(near ? 4000 : 16000)
            }
        }
        thread.name = "bcu.guard.cursor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Returns whether the cursor is near the agent display.
    @discardableResult
    private func checkCursor() -> Bool {
        let displays = AgentDisplay.running
        guard !displays.isEmpty, let p = CGEvent(source: nil)?.location else { return false }
        guard let agent = displays.first(where: { $0.liveBounds.contains(p) })?.liveBounds else {
            return displays.contains { $0.liveBounds.insetBy(dx: -400, dy: -400).contains(p) }
        }
        let q = nearestUserPoint(p, agent: agent)
        CGWarpMouseCursorPosition(q)
        CGAssociateMouseAndMouseCursorPosition(1)
        let tapState: String
        if let tap {
            let on = CGEvent.tapIsEnabled(tap: tap)
            if !on { CGEvent.tapEnable(tap: tap, enable: true) }
            tapState = on ? "tap on" : "tap was off, re-enabled"
        } else {
            tapState = "tap not installed"
        }
        lock.lock()
        let log = nowMs() - lastEscapeLogMs > 2000
        if log { lastEscapeLogMs = nowMs() }
        lock.unlock()
        if log {
            Log.info("guard: cursor was on the agent display at \(Int(p.x)),\(Int(p.y)); moved it back to \(Int(q.x)),\(Int(q.y)) (\(tapState); agent display at \(agent.short))")
        }
        return true
    }

    // MARK: Agent actions

    /// Mark `pid` as being acted on. Activations of it until `endAction` +
    /// a grace period are treated as caused by the agent.
    public func beginAction(pid: pid_t, cause: String, strict: Bool = false) {
        // Whatever is in front right now (other than the target) is the user's app.
        let front = BCUFrontProcessPID()
        if front != 0 && front != pid && front != getpid() && !isTainted(front) {
            noteUserFront(front)
        }
        lock.lock()
        taints[pid] = (until: .infinity, cause: cause, strict: strict)
        lock.unlock()
    }

    public func endAction(pid: pid_t, graceMs: Double = 700) {
        lock.lock()
        if let t = taints[pid] { taints[pid] = (until: nowMs() + graceMs, cause: t.cause, strict: t.strict) }
        lock.unlock()
    }

    public func isTainted(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = taints[pid] else { return false }
        if t.until < nowMs() { taints[pid] = nil; return false }
        return true
    }

    public var activeTaints: [pid_t] {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        return taints.filter { $0.value.until >= now }.map { $0.key }
    }

    /// The app the user is in, as far as the guard knows.
    public var userFront: pid_t {
        lock.lock(); defer { lock.unlock() }
        return userFrontPid
    }

    /// True when the user recently clicked or switched apps, so an activation
    /// right now is theirs.
    func userCausedRecently(withinMs: Double = 400) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        return now - lastUserMouseDownMs < withinMs || now - lastUserSwitchKeyMs < withinMs
    }

    /// Whether `pid` becoming frontmost right now is the agent's doing.
    /// While an action on it is running: yes, unless the user clicked or
    /// switched apps. In the grace period after: only if the user hasn't
    /// pressed any key or clicked either (launchers, Terminal `open`, links).
    func debugCause(_ pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        let until = taints[pid].map { $0.until == .infinity ? "running" : "\(Int($0.until - now))ms left" } ?? "none"
        return "taint=\(until) key=\(Int(now - lastUserKeyMs))ms click=\(Int(now - lastUserMouseDownMs))ms"
    }

    func agentCaused(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        guard let t = taints[pid], t.until >= now else { return false }
        let click = !t.strict && now - lastUserMouseDownMs < 400
        let clickOrSwitch = click || now - lastUserSwitchKeyMs < 400
        if t.until == .infinity { return !clickOrSwitch }
        return !clickOrSwitch && (t.strict || now - lastUserKeyMs >= 1500)
    }

    func record(_ summary: String) {
        let e = GuardEvent(time: Date(), summary: summary)
        lock.lock()
        events.append(e)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        lock.unlock()
        Log.info("guard: \(summary)")
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    // MARK: Activation

    private func noteUserFront(_ pid: pid_t) {
        lock.lock()
        userFrontPid = pid
        userFrontWindow = nil
        lock.unlock()
        let window = AX.focusedWindowID(pid)
        lock.lock()
        guard userFrontPid == pid else { lock.unlock(); return }
        userFrontWindow = window
        lock.unlock()
    }

    // MARK: Front monitor

    private var monitorDepth = 0
    private var monitorLog: [(ms: Double, pid: pid_t, agent: Bool)] = []
    private var monitorStartMs = 0.0

    /// Sample the front process every 5 ms until `stopMonitor`, so each action
    /// can report exactly what happened to the user's focus.
    public func startMonitor() {
        lock.lock()
        monitorDepth += 1
        let first = monitorDepth == 1
        if first {
            monitorLog = [(0, BCUFrontProcessPID(), false)]
            monitorStartMs = nowMs()
        }
        lock.unlock()
        guard first else { return }
        let thread = Thread { [weak self] in
            while let self {
                self.lock.lock()
                let active = self.monitorDepth > 0
                let last = self.monitorLog.last?.pid
                self.lock.unlock()
                if !active { break }
                let pid = BCUFrontProcessPID()
                if pid != last {
                    let agent = pid != 0 && pid != self.userFront && self.agentCaused(pid)
                    self.lock.lock()
                    self.monitorLog.append((nowMs() - self.monitorStartMs, pid, agent))
                    self.lock.unlock()
                    // Restore here rather than waiting for NSWorkspace's
                    // notification, which arrives ~25 ms later.
                    if agent {
                        self.restoreUserFront(reason: "self-activation", immediate: true)
                    }
                }
                usleep(1000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops sampling after `tailMs` and returns a description of any front
    /// changes, or nil if the user's front app never changed.
    public func stopMonitor(tailMs: Double = 400) -> String? {
        sleepMs(tailMs)
        lock.lock()
        monitorDepth = max(0, monitorDepth - 1)
        let log = monitorLog
        lock.unlock()
        // Report only when the agent caused a change; the user's own app
        // switches during an action aren't news.
        guard log.count > 1, log.contains(where: { $0.agent }) else { return nil }
        func name(_ pid: pid_t) -> String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }
        var parts: [String] = []
        for (i, entry) in log.enumerated() where i > 0 {
            let end = i + 1 < log.count ? log[i + 1].ms : nowMs() - monitorStartMs
            parts.append("\(name(entry.pid)) was frontmost from \(Int(entry.ms)) ms for \(Int(end - entry.ms)) ms")
        }
        let final = log.last!.pid == log.first!.pid ? "then the user's app (\(name(log.first!.pid))) was back in front" : "and is STILL in front"
        return "Front app changed: " + parts.joined(separator: "; ") + ", " + final
    }

    private func activated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        Log.info("guard: activated \(app.localizedName ?? "?") pid \(pid) tainted=\(isTainted(pid)) userFront=\(userFront) agentCaused=\(agentCaused(pid)) \(debugCause(pid))")
        if pid == getpid() { return }
        if agentCaused(pid) && pid != userFront {
            // The monitor thread usually restored already; this is the backup path.
            if BCUFrontProcessPID() == pid { restoreUserFront(reason: "activation") }
        } else {
            // Off the main thread: AX calls into Electron apps can be slow.
            DispatchQueue.global(qos: .userInitiated).async { self.noteUserFront(pid) }
        }
    }

    private func taintCause(_ pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        return taints[pid]?.cause ?? "an agent action"
    }

    /// Give the front back to the user's app, then replay held keystrokes.
    /// `immediate`: issue the SkyLight call on the calling thread (the 1 ms
    /// monitor), with the user's app and window captured before the action,
    /// so the user's app is back in front as fast as WindowServer allows.
    func restoreUserFront(reason: String, immediate: Bool = false) {
        lock.lock()
        if restoring { lock.unlock(); return }
        restoring = true
        let pid = userFrontPid
        let window = userFrontWindow ?? 0
        lock.unlock()

        let t0 = nowMs()
        var status: Int32 = 0
        if immediate && pid != 0 { status = BCUSetFrontProcess(pid, window, 0x200) }
        let t1 = nowMs()

        restoreQueue.async {
            if pid != 0 {
                if !immediate { status = BCUSetFrontProcess(pid, window, 0x200) }
                if window != 0 { _ = BCUPostMakeKeyRecords(pid, window) }
                let deadline = nowMs() + 500
                while BCUFrontProcessPID() != pid && nowMs() < deadline { sleepMs(1) }
                Log.info("guard: restore (\(reason)) setFront=\(status) call \(Int(t1 - t0)) ms, front back after \(Int(nowMs() - t0)) ms")
            }
            self.lock.lock()
            self.holding = false
            self.restoring = false
            let swapping = self.swapHolds > 0
            self.lock.unlock()
            if !swapping {
                let n = self.drain()
                if n > 0 { self.record("held \(n) of your key events during a focus change (\(reason)) and replayed them into your app") }
            }
        }
    }

    // MARK: Tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.lock()
            let log = nowMs() - lastTapDisabledLogMs > 5000
            if log { lastTapDisabledLogMs = nowMs() }
            lock.unlock()
            if log { Log.info("guard: macOS disabled the event tap (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabled") }
            return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == FocusGuard.replayMarker {
            return event
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .tabletPointer:
            let p = event.location
            if let agent = AgentDisplay.containing(p)?.liveBounds {
                let q = nearestUserPoint(p, agent: agent)
                event.location = q
                CGWarpMouseCursorPosition(q)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            if type != .mouseMoved {
                lock.lock(); let pressHeld = held.contains { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) }; lock.unlock()
                if pressHeld { hold(event); return nil }
            }
            return event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lock.lock(); lastUserMouseDownMs = nowMs(); let swapping = swapHolds > 0 || draining; lock.unlock()
            if AgentDisplay.containing(event.location) != nil { return nil }
            // A click now would make the user's window key mid-swap; hold it.
            if swapping { hold(event); return nil }
            return event
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            lock.lock(); let swapping = swapHolds > 0 || draining || held.contains { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) }; lock.unlock()
            if swapping { hold(event); return nil }
            return event
        case .scrollWheel:
            if AgentDisplay.containing(event.location) != nil { return nil }
            return event
        case .keyDown, .keyUp, .flagsChanged:
            if type == .keyDown {
                lock.lock()
                lastUserKeyMs = nowMs()
                if event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 48 { lastUserSwitchKeyMs = nowMs() }
                lock.unlock()
            }
            lock.lock()
            let alreadyHolding = holding || swapHolds > 0 || draining
            let now = nowMs()
            let anyTaint = taints.values.contains { $0.until >= now }
            lock.unlock()
            if alreadyHolding {
                hold(event)
                return nil
            }
            // Nothing to protect against unless the agent is mid-action.
            guard anyTaint else { return event }
            let front = BCUFrontProcessPID()
            if front != 0 && front != userFront && agentCaused(front) {
                lock.lock(); holding = true; lock.unlock()
                hold(event)
                restoreUserFront(reason: "keystroke")
                return nil
            }
            return event
        default:
            return event
        }
    }

    /// Hold the user's keys and clicks until `endHold`, then replay them in
    /// order. Used while the agent briefly owns an app's key window, so
    /// nothing the user types lands in the agent's window and no click of
    /// theirs moves key focus mid-swap.
    public func beginHold() {
        lock.lock(); swapHolds += 1; lock.unlock()
    }

    public func endHold() {
        lock.lock()
        swapHolds = max(0, swapHolds - 1)
        guard swapHolds == 0, !holding else { lock.unlock(); return }
        lock.unlock()
        let n = drain()
        if n > 0 { Log.info("guard: replayed \(n) held events after a key-window swap") }
    }

    /// Replay held events in order, about 1 ms apart. Events the user makes
    /// meanwhile queue up behind them, so nothing is reordered.
    @discardableResult
    private func drain() -> Int {
        lock.lock()
        if draining { lock.unlock(); return 0 }
        draining = true
        lock.unlock()
        var n = 0
        while true {
            lock.lock()
            if held.isEmpty || holding || swapHolds > 0 { draining = false; lock.unlock(); break }
            let e = held.removeFirst()
            lock.unlock()
            e.setIntegerValueField(.eventSourceUserData, value: FocusGuard.replayMarker)
            e.post(tap: .cghidEventTap)
            n += 1
            usleep(1000)
        }
        return n
    }

    private func hold(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        lock.lock()
        held.append(copy)
        lock.unlock()
    }

    private func nearestUserPoint(_ p: CGPoint, agent: CGRect) -> CGPoint {
        var best = p
        var bestDistance = CGFloat.infinity
        let agents = AgentDisplay.running.map(\.liveBounds)
        for id in AgentDisplay.userDisplayIDs() {
            let r = CGDisplayBounds(id)
            // Skip any display that overlaps the agent's (mirroring, mid-rearrangement).
            let overlap = r.intersection(agent)
            if !overlap.isNull && overlap.width > 0 && overlap.height > 0 { continue }
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if agent.contains(q) || agents.contains(where: { $0.contains(q) }) { continue }
            if d < bestDistance { bestDistance = d; best = q }
        }
        if bestDistance == .infinity {
            let main = CGDisplayBounds(CGMainDisplayID())
            return CGPoint(x: main.midX, y: main.midY)
        }
        return best
    }

    // MARK: Tests

    /// Test only: push the cursor onto the agent display the way an escape
    /// would, and measure how long it stays there. `via`: "warp" bypasses the
    /// tap entirely; "tap_off" disables the tap and posts HID moves into it.
    public func escapeTest(via: String) -> String {
        guard let display = AgentDisplay.running.first, let start = CGEvent(source: nil)?.location else { return "no agent display" }
        let agent = display.liveBounds
        let target = CGPoint(x: agent.midX, y: agent.midY)
        let t0 = nowMs()
        switch via {
        case "tap_off":
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
                e.post(tap: .cghidEventTap)
            }
        default:
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        var seenOn = false, backAt: Double?
        while nowMs() - t0 < 300 {
            if let p = CGEvent(source: nil)?.location {
                if agent.contains(p) { seenOn = true } else if seenOn { backAt = nowMs() - t0; break }
            }
            usleep(500)
        }
        let end = CGEvent(source: nil)?.location ?? .zero
        // Put the cursor back where the user left it.
        CGWarpMouseCursorPosition(start)
        CGAssociateMouseAndMouseCursorPosition(1)
        let tapOn = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        if !seenOn { return "\(via): cursor never reached the agent display (ended at \(Int(end.x)),\(Int(end.y)))" }
        guard let backAt else { return "\(via): cursor STILL on the agent display after 300 ms" }
        return "\(via): cursor back on the user's display after \(String(format: "%.1f", backAt)) ms at \(Int(end.x)),\(Int(end.y)); tap \(tapOn ? "on" : "off")"
    }
}

private func guardTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let g = FocusGuard.shared else { return Unmanaged.passUnretained(event) }
    guard let out = g.handle(type: type, event: event) else { return nil }
    return Unmanaged.passUnretained(out)
}

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
    /// The user's recent input, for waiting until they pause (see `QuietWait`).
    public let activity = UserActivity()

    private let lock = NSLock()
    /// An app the agent is acting on. `count`: actions running now (sessions
    /// can overlap in one app); `until`: when the grace period after the last
    /// one ends. strict: the user is driving the app from the expanded view,
    /// so their clicks and keys (which land in this app's panel) never
    /// explain an activation.
    private struct Taint {
        var count: Int
        var until: Double
        var cause: String
        var strict: Bool
    }
    private var taints: [pid_t: Taint] = [:]
    /// Apps whose key window an agent has moved to one of its windows right
    /// now (see `beginSwap`), with nesting counts.
    private var swapping: [pid_t: Int] = [:]
    /// Keys the user typed into an app while it was mid-swap, held until key
    /// is back on their window. With when the first one came.
    private var pidHeld: [pid_t: (sinceMs: Double, events: [CGEvent])] = [:]
    private var userFrontPid: pid_t = 0
    private var userFrontWindow: CGWindowID?
    private var lastUserMouseDownMs = 0.0
    private var lastUserSwitchKeyMs = 0.0
    private var lastUserKeyMs = 0.0
    private var holding = false
    private var holdingSinceMs = 0.0
    /// With the app that was in front when each came: a key goes back to
    /// that app, not to whatever took the front meanwhile.
    private var held: [(event: CGEvent, front: pid_t)] = []
    private var heldSinceMs = 0.0
    /// Holds of all the user's input in progress (see `beginHold`).
    private var holdTokens: Set<Int> = []
    private var nextHoldToken = 1
    private var holdSinceMs = 0.0
    /// Keys whose key-down reached the app (passed or replayed) and whose
    /// key-up hasn't yet: that key-up goes straight on, never held, so a
    /// key's down and up are never split (a key held down that long is
    /// what the system and the app see, and a key-up carries no text).
    private var downDelivered: [Int64: Int] = [:]
    /// A drain is due again (it found key on an agent window).
    private var drainRetryScheduled = false
    /// Replaying held events; anything new queues behind them to keep order.
    private var draining = false
    private var restoring = false
    private var tap: CFMachPort?
    private var lastEscapeLogMs = 0.0
    private var lastTapDisabledLogMs = 0.0
    private let restoreQueue = DispatchQueue(label: "bcu.guard.restore")
    private var events: [GuardEvent] = []

    static let replayMarker: Int64 = 0x4243_5552
    /// No hold of all the user's input lasts longer than this, whatever the
    /// agent is stuck on (a hung app, a busy main thread).
    public static let maxHoldMs = 2000.0
    /// How long a held key waits for the app it was typed into to be back in front.
    static let frontBackMs = 500.0
    /// Keys typed into an app mid-swap are held at most this long.
    static let maxPidHoldMs = 5000.0
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
        let watchdog = Thread { [weak self] in
            while let s = self {
                s.watchHolds()
                usleep(50_000)
            }
        }
        watchdog.name = "bcu.guard.holds"
        watchdog.qualityOfService = .userInteractive
        watchdog.start()
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
        var t = taints[pid] ?? Taint(count: 0, until: .infinity, cause: cause, strict: strict)
        t.count += 1
        t.until = .infinity
        t.cause = cause
        t.strict = strict
        taints[pid] = t
        lock.unlock()
    }

    public func endAction(pid: pid_t, graceMs: Double = 700) {
        lock.lock()
        if var t = taints[pid] {
            t.count = max(0, t.count - 1)
            // Another session's action in the same app is still running.
            if t.count == 0 { t.until = nowMs() + graceMs }
            taints[pid] = t
        }
        lock.unlock()
    }

    public func isTainted(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = taints[pid] else { return false }
        if t.count == 0 && t.until < nowMs() { taints[pid] = nil; return false }
        return true
    }

    public var activeTaints: [pid_t] {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        return taints.filter { $0.value.count > 0 || $0.value.until >= now }.map { $0.key }
    }

    // MARK: Key swaps

    /// An agent is about to make one of its windows key in `pid`. Until
    /// `endSwap`, keys the user types while `pid` is in front are held (even
    /// if they weren't in it when the swap began: they may switch to it
    /// mid-swap), clicks on its windows are held, nothing else moves its key
    /// window, and they're replayed once key is back on the user's window.
    public func beginSwap(_ pid: pid_t) {
        lock.lock(); swapping[pid, default: 0] += 1; lock.unlock()
    }

    public func endSwap(_ pid: pid_t) {
        lock.lock()
        if let n = swapping[pid] { swapping[pid] = n > 1 ? n - 1 : nil }
        let done = swapping[pid] == nil
        lock.unlock()
        if done { releasePidHeld(pid) }
    }

    public func isSwapping(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return swapping[pid] != nil
    }

    /// Keys held for `pid` mid-swap go back in the queue (in front: they came
    /// first) and replay once it's safe.
    private func releasePidHeld(_ pid: pid_t) {
        lock.lock()
        if let p = pidHeld.removeValue(forKey: pid), !p.events.isEmpty {
            if held.isEmpty { heldSinceMs = p.sinceMs }
            held.insert(contentsOf: p.events.map { ($0, pid) }, at: 0)
        }
        lock.unlock()
        drain()
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
        let until = taints[pid].map { $0.count > 0 ? "running" : "\(Int($0.until - now))ms left" } ?? "none"
        return "taint=\(until) key=\(Int(now - lastUserKeyMs))ms click=\(Int(now - lastUserMouseDownMs))ms"
    }

    func agentCaused(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        guard let t = taints[pid], t.count > 0 || t.until >= now else { return false }
        let click = !t.strict && now - lastUserMouseDownMs < 400
        let clickOrSwitch = click || now - lastUserSwitchKeyMs < 400
        if t.count > 0 { return !clickOrSwitch }
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
        var window = AX.focusedWindowID(pid)
        if let w = window, Self.onAgentDisplay(w) { window = nil }
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
            DispatchQueue.global(qos: .userInitiated).async {
                self.reclaimWhenSafe(pid)
                self.noteUserFront(pid)
            }
        }
    }

    static func onAgentDisplay(_ id: CGWindowID) -> Bool {
        guard let info = WindowList.info(id) else { return false }
        return AgentDisplay.running.contains { $0.liveBounds.intersects(info.bounds) }
    }

    /// `reclaimKey`, but never in the middle of a key swap: a swap in any
    /// session holds the input lock from before it moves key until key is
    /// back, so taking the lock waits for it to end.
    public func reclaimWhenSafe(_ pid: pid_t) {
        Engine.inputLock.lock()
        defer { Engine.inputLock.unlock() }
        if isSwapping(pid) { return }
        reclaimKey(pid)
    }

    /// `reclaimWhenSafe` again a little later, for records that may still
    /// land (a swap that failed half-way).
    public func scheduleReclaim(_ pid: pid_t) {
        for ms in [150, 500, 1200] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(ms)) {
                self.reclaimWhenSafe(pid)
            }
        }
    }

    /// The user's front app must never have an agent's window as its key
    /// window outside a swap: their typing would go there. It can happen
    /// when the app comes back to the front just as a swap ends (a system
    /// alert took the front for a moment, say), because AppKit makes the
    /// window that was key last key again. Hand key to the user's window in
    /// that app: `prefer` if given, else the one they were last in, else its
    /// frontmost standard window on their screens. Returns whether it had to.
    /// Callers outside a swap go through `reclaimWhenSafe`.
    @discardableResult
    public func reclaimKey(_ pid: pid_t, prefer: CGWindowID? = nil) -> Bool {
        guard BCUFrontProcessPID() == pid, let key = AX.focusedWindowID(pid), Self.onAgentDisplay(key) else { return false }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        guard let user = userWindow(of: pid, prefer: prefer) else {
            record("\(name) was in front with an agent window (\(key)) as its key window; COULD NOT give key back: no window of the user's on their screens")
            return true
        }
        var ok = false
        for settle in [5.0, 120.0] {
            _ = KeyScope.postRecords(pid: pid, from: key, to: user, settle: settle)
            KeyScope.awaitKey(pid: pid, target: user, budgetMs: settle < 50 ? 250 : 400)
            ok = AX.focusedWindowID(pid) == user
            if ok { break }
        }
        if !ok, let ax = AX.window(pid: pid, id: user) {
            // The window is the user's front one in the app they're in, so
            // raising it changes nothing on screen but makes it key.
            AX.perform(ax, "AXRaise")
            KeyScope.awaitKey(pid: pid, target: user, budgetMs: 300)
            ok = AX.focusedWindowID(pid) == user
        }
        record("\(name) was in front with an agent window (\(key)) as its key window; \(ok ? "gave key back to" : "COULD NOT give key back to") the user's window \(user)")
        return true
    }

    /// The window of `pid` the user would expect to be key: a standard
    /// window on their screens (not a popup, tooltip or suggestion list).
    func userWindow(of pid: pid_t, prefer: CGWindowID? = nil) -> CGWindowID? {
        let agents = AgentDisplay.running.map(\.liveBounds)
        let onScreen = WindowList.of(pid: pid, onScreenOnly: true).filter { w in
            w.layer == 0 && w.alpha > 0 && w.bounds.width > 40 && !agents.contains { $0.intersects(w.bounds) }
        }
        let ids = Set(onScreen.map(\.id))
        lock.lock()
        let last = userFrontPid == pid ? userFrontWindow : nil
        lock.unlock()
        let axWindows = AX.windows(pid)
        func standard(_ id: CGWindowID) -> Bool {
            guard let ax = axWindows.first(where: { AX.windowID($0) == id }) else { return false }
            return AX.string(ax, "AXSubrole") == "AXStandardWindow" && AX.bool(ax, "AXMinimized") != true
        }
        let candidates = [prefer, last].compactMap { $0 } + onScreen.map(\.id)
        return candidates.first { ids.contains($0) && standard($0) }
    }

    /// Nothing the user types into `pid` now can land in an agent's window:
    /// its key window (if it has one) isn't on an agent display. False when
    /// that can't be told (the app isn't answering).
    func keySafe(_ pid: pid_t) -> Bool {
        let agents = AgentDisplay.running.map(\.liveBounds)
        guard WindowList.of(pid: pid).contains(where: { w in agents.contains { $0.intersects(w.bounds) } }) else { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &value)
        if err == .noValue { return true }
        guard err == .success, let v = value, CFGetTypeID(v) == AXUIElementGetTypeID(),
              let id = AX.windowID(unsafeBitCast(v, to: AXUIElement.self)) else { return false }
        return !Self.onAgentDisplay(id)
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
                // Not while an agent's window is key there for a swap: that
                // would move key under the agent's keystrokes. The swap gives
                // key back itself.
                if window != 0 && !self.isSwapping(pid) { _ = BCUPostMakeKeyRecords(pid, window) }
                let deadline = nowMs() + 500
                while BCUFrontProcessPID() != pid && nowMs() < deadline { sleepMs(1) }
                Log.info("guard: restore (\(reason)) setFront=\(status) call \(Int(t1 - t0)) ms, front back after \(Int(nowMs() - t0)) ms")
            }
            self.lock.lock()
            self.holding = false
            self.restoring = false
            self.lock.unlock()
            let n = self.drain()
            if n > 0 { self.record("held \(n) of your key events during a focus change (\(reason)) and replayed them into your app") }
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
            if type == .keyDown || type == .keyUp { noteDelivered(event, type) }
            return event
        }
        activity.note(type, event)
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
                lock.lock(); let pressHeld = held.contains { Self.isMouseDown($0.event.type) }; lock.unlock()
                if pressHeld { hold(event); return nil }
            }
            return event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lock.lock(); lastUserMouseDownMs = nowMs(); let holdAll = !holdTokens.isEmpty || draining; let anySwap = !swapping.isEmpty; lock.unlock()
            if AgentDisplay.containing(event.location) != nil { return nil }
            // A click now would make the user's window key mid-swap; hold it.
            if holdAll { hold(event); return nil }
            // Even in an app they weren't in: a click on its window would
            // activate it and move key under the agent's keystrokes.
            if anySwap, let pid = Self.windowOwner(at: event.location), isSwapping(pid) { hold(event); return nil }
            return event
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            lock.lock(); let holdIt = !holdTokens.isEmpty || draining || held.contains { Self.isMouseDown($0.event.type) }; lock.unlock()
            if holdIt { hold(event); return nil }
            return event
        case .scrollWheel:
            if AgentDisplay.containing(event.location) != nil { return nil }
            return event
        case .keyDown, .keyUp, .flagsChanged:
            let cmdTab = type != .flagsChanged && event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 48
            if type == .keyDown {
                lock.lock()
                lastUserKeyMs = nowMs()
                if cmdTab { lastUserSwitchKeyMs = nowMs() }
                lock.unlock()
            }
            if type == .keyUp {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                lock.lock()
                let isDown = { (e: CGEvent) in e.type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode) == code }
                let waiting = held.contains { isDown($0.event) } || pidHeld.values.contains { $0.events.contains(where: isDown) }
                let delivered = (downDelivered[code] ?? 0) > 0 && !waiting
                lock.unlock()
                if delivered { return passKey(event, type) }
            }
            lock.lock()
            let alreadyHolding = holding || !holdTokens.isEmpty || draining || !held.isEmpty
            let anySwap = !swapping.isEmpty || !pidHeld.isEmpty
            let now = nowMs()
            let anyTaint = taints.values.contains { $0.count > 0 || $0.until >= now }
            lock.unlock()
            if alreadyHolding {
                hold(event)
                return nil
            }
            // Keys for an app whose key window is an agent's right now wait
            // for it to be the user's again. Modifier changes carry no text,
            // and cmd+Tab goes to the app switcher, not the app.
            if anySwap && type != .flagsChanged && !cmdTab {
                let front = BCUFrontProcessPID()
                lock.lock()
                let mid = swapping[front] != nil || pidHeld[front] != nil
                if mid, let copy = event.copy() {
                    var p = pidHeld[front] ?? (nowMs(), [])
                    p.events.append(copy)
                    pidHeld[front] = p
                }
                lock.unlock()
                if mid { return nil }
            }
            // Nothing to protect against unless the agent is mid-action.
            guard anyTaint else { return passKey(event, type) }
            let front = BCUFrontProcessPID()
            if front != 0 && front != userFront && agentCaused(front) {
                lock.lock(); if !holding { holding = true; holdingSinceMs = nowMs() }; lock.unlock()
                hold(event)
                restoreUserFront(reason: "keystroke")
                return nil
            }
            return passKey(event, type)
        default:
            return event
        }
    }

    /// A key event goes on to the app now.
    private func passKey(_ event: CGEvent, _ type: CGEventType) -> CGEvent {
        if type == .keyDown || type == .keyUp { noteDelivered(event, type) }
        return event
    }

    private func noteDelivered(_ event: CGEvent, _ type: CGEventType) {
        // Autorepeats of a key that's down add nothing to undo.
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        if type == .keyDown {
            downDelivered[code, default: 0] += 1
        } else if let n = downDelivered[code] {
            downDelivered[code] = n > 1 ? n - 1 : nil
        }
        lock.unlock()
    }

    private static func isMouseDown(_ t: CGEventType) -> Bool {
        t == .leftMouseDown || t == .rightMouseDown || t == .otherMouseDown
    }

    private static func isKey(_ t: CGEventType) -> Bool {
        t == .keyDown || t == .keyUp || t == .flagsChanged
    }

    /// The app whose window is on top at a global point (not this app's
    /// click-through covers).
    static func windowOwner(at p: CGPoint) -> pid_t? {
        let me = getpid()
        return WindowList.all(onScreenOnly: true).first { w in
            w.pid != me && w.alpha > 0 && w.layer < Int(CGWindowLevelForKey(.mainMenuWindow)) && w.bounds.contains(p)
        }?.pid
    }

    /// Hold the user's keys and clicks until `endHold`, then replay them in
    /// order. Used while the agent briefly owns an app's key window, so
    /// nothing the user types lands in the agent's window and no click of
    /// theirs moves key focus mid-swap. Never longer than `maxHoldMs` in all.
    public func beginHold() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if holdTokens.isEmpty { holdSinceMs = nowMs() }
        let token = nextHoldToken
        nextHoldToken += 1
        holdTokens.insert(token)
        return token
    }

    public func endHold(_ token: Int) {
        lock.lock()
        holdTokens.remove(token)
        let last = holdTokens.isEmpty && !holding
        lock.unlock()
        guard last else { return }
        let n = drain()
        if n > 0 { Log.info("guard: replayed \(n) held events after a key-window swap") }
    }

    /// Release any hold older than `maxHoldMs`, and keys held for an app
    /// mid-swap after `maxPidHoldMs`: a hung app or a stuck step must never
    /// leave the user's keyboard and mouse dead.
    private func watchHolds() {
        let now = nowMs()
        lock.lock()
        var what: [String] = []
        if !holdTokens.isEmpty && now - holdSinceMs > Self.maxHoldMs { holdTokens.removeAll(); what.append("a key swap") }
        if holding && now - holdingSinceMs > Self.maxHoldMs { holding = false; what.append("a focus change") }
        let stale = !held.isEmpty && !draining && now - heldSinceMs > Self.maxHoldMs
        let stalePids = pidHeld.filter { now - $0.value.sinceMs > Self.maxPidHoldMs }.map(\.key)
        lock.unlock()
        if !what.isEmpty { record("released your input after \(Int(Self.maxHoldMs)) ms held for \(what.joined(separator: " and "))") }
        if !what.isEmpty || stale { drain(force: true) }
        for pid in stalePids {
            lock.lock()
            let p = pidHeld.removeValue(forKey: pid)
            let still = swapping[pid] != nil
            if let p, !still {
                if held.isEmpty { heldSinceMs = p.sinceMs }
                held.insert(contentsOf: p.events.map { ($0, pid) }, at: 0)
            }
            lock.unlock()
            if still, let p {
                // The app has been mid-swap all this time (it isn't answering).
                record("COULD NOT give key back in pid \(pid) within \(Int(Self.maxPidHoldMs)) ms: dropped \(p.events.count) of your key events rather than type them into an agent's window")
            } else {
                drain(force: true)
            }
        }
    }

    /// Replay held events in order, about 1 ms apart. Events the user makes
    /// meanwhile queue up behind them, so nothing is reordered. A key goes
    /// on only once the front app's key window is the user's (never an
    /// agent's), and a click on an app mid-swap waits for the swap. `force`
    /// (the watchdog): clicks go on regardless, and keys that still can't go
    /// to the user's window are dropped rather than typed into an agent's.
    @discardableResult
    private func drain(force: Bool = false) -> Int {
        lock.lock()
        if draining { lock.unlock(); return 0 }
        draining = true
        lock.unlock()
        var n = 0, dropped = 0
        var safeFor: pid_t = -1
        var retry = false
        var gaveUp: Set<pid_t> = []
        while true {
            lock.lock()
            if held.isEmpty || holding || !holdTokens.isEmpty { draining = false; lock.unlock(); break }
            let (e, typedInto) = held[0]
            let swappingNow = swapping
            lock.unlock()
            if Self.isKey(e.type) {
                // Typed into an app that has since lost the front for a
                // moment (a system alert, a self-activation the guard is
                // undoing): wait for it to be back.
                let front = BCUFrontProcessPID()
                if typedInto != 0 && front != typedInto && !gaveUp.contains(typedInto) {
                    let deadline = nowMs() + Self.frontBackMs
                    while BCUFrontProcessPID() != typedInto && nowMs() < deadline { usleep(2000) }
                    // Let it finish activating before keys reach it.
                    if BCUFrontProcessPID() == typedInto { usleep(30_000) } else { gaveUp.insert(typedInto) }
                }
            }
            if Self.isKey(e.type) && e.type != .flagsChanged {
                let front = BCUFrontProcessPID()
                if swappingNow[front] != nil {
                    // That app's key window is an agent's for now; its swap
                    // replays these when it ends.
                    lock.lock()
                    removeHeld(e)
                    var p = pidHeld[front] ?? (nowMs(), [])
                    p.events.append(e)
                    pidHeld[front] = p
                    lock.unlock()
                    continue
                }
                if safeFor != front {
                    if !keySafe(front) {
                        // Reclaim, but without waiting on a swap that may be stuck.
                        if Engine.inputLock.lock(before: Date().addingTimeInterval(0.05)) {
                            if !isSwapping(front) { reclaimKey(front) }
                            Engine.inputLock.unlock()
                        }
                    }
                    if !keySafe(front) {
                        if !force { retry = true; lock.lock(); draining = false; lock.unlock(); break }
                        lock.lock(); removeHeld(e); lock.unlock()
                        dropped += 1
                        continue
                    }
                    safeFor = front
                }
            } else if Self.isMouseDown(e.type) {
                let owner = Self.windowOwner(at: e.location)
                if !force, let owner, swappingNow[owner] != nil {
                    lock.lock(); draining = false; lock.unlock()
                    break
                }
                lock.lock(); removeHeld(e); lock.unlock()
                e.setIntegerValueField(.eventSourceUserData, value: FocusGuard.replayMarker)
                e.post(tap: .cghidEventTap)
                n += 1
                // A click can switch apps and move key: keys typed after it
                // go on once that has happened, to where it put them.
                if let owner, owner != BCUFrontProcessPID(), NSRunningApplication(processIdentifier: owner)?.activationPolicy == .regular {
                    let deadline = nowMs() + 300
                    while BCUFrontProcessPID() != owner && nowMs() < deadline { usleep(2000) }
                }
                safeFor = -1
                usleep(1000)
                continue
            }
            lock.lock(); removeHeld(e); lock.unlock()
            e.setIntegerValueField(.eventSourceUserData, value: FocusGuard.replayMarker)
            e.post(tap: .cghidEventTap)
            n += 1
            usleep(1000)
        }
        if dropped > 0 {
            record("COULD NOT give key back to your window in time: dropped \(dropped) of your key events rather than type them into an agent's window")
        }
        if retry { scheduleDrain() }
        return n
    }

    /// Take `e` out of the queue once it's replayed or moved. By identity,
    /// not position: a swap ending meanwhile puts its held keys in front.
    private func removeHeld(_ e: CGEvent) {
        if let i = held.firstIndex(where: { $0.event === e }) { held.remove(at: i) }
    }

    private func scheduleDrain() {
        lock.lock()
        if drainRetryScheduled { lock.unlock(); return }
        drainRetryScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.lock.lock(); self.drainRetryScheduled = false; self.lock.unlock()
            self.drain()
        }
    }

    private func hold(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        let front = Self.isKey(event.type) ? BCUFrontProcessPID() : 0
        lock.lock()
        if held.isEmpty { heldSinceMs = nowMs() }
        held.append((copy, front))
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

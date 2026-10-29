import AppKit
import CoreGraphics
import CPrivate

public struct GuardEvent {
    public let time: Date
    public let summary: String
}

/// Keeps the user's focus, keystrokes and cursor theirs.
///
/// - Cursor fence: mouse moves that would land on the agent display are pulled back.
/// - Keystroke hold: if an app the agent is acting on makes itself frontmost,
///   the user's keystrokes are held, the user's app is put back in front, and
///   the keys are replayed into it. Nothing typed lands in the agent's window.
/// - Activation watch: the same restore runs when such an activation is seen
///   even without typing.
public final class FocusGuard {
    public let display: AgentDisplay
    public var onEvent: ((GuardEvent) -> Void)?

    private let lock = NSLock()
    private var taints: [pid_t: (until: Double, cause: String)] = [:]
    private var userFrontPid: pid_t = 0
    private var userFrontWindow: CGWindowID?
    private var lastUserMouseDownMs = 0.0
    private var lastUserSwitchKeyMs = 0.0
    private var lastUserKeyMs = 0.0
    private var holding = false
    private var held: [CGEvent] = []
    private var restoring = false
    private var tap: CFMachPort?
    private let restoreQueue = DispatchQueue(label: "bcu.guard.restore")
    private var events: [GuardEvent] = []

    static let replayMarker: Int64 = 0x4243_5552
    fileprivate static weak var shared: FocusGuard?

    public init(display: AgentDisplay) {
        self.display = display
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
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
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

    // MARK: Agent actions

    /// Mark `pid` as being acted on. Activations of it until `endAction` +
    /// a grace period are treated as caused by the agent.
    public func beginAction(pid: pid_t, cause: String) {
        // Whatever is in front right now (other than the target) is the user's app.
        let front = BCUFrontProcessPID()
        if front != 0 && front != pid && front != getpid() && !isTainted(front) {
            noteUserFront(front)
        }
        lock.lock()
        taints[pid] = (until: .infinity, cause: cause)
        lock.unlock()
    }

    public func endAction(pid: pid_t, graceMs: Double = 700) {
        lock.lock()
        if let t = taints[pid] { taints[pid] = (until: nowMs() + graceMs, cause: t.cause) }
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
        let clickOrSwitch = now - lastUserMouseDownMs < 400 || now - lastUserSwitchKeyMs < 400
        if t.until == .infinity { return !clickOrSwitch }
        return !clickOrSwitch && now - lastUserKeyMs >= 1500
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
            let replay = self.held
            self.held.removeAll()
            self.holding = false
            self.restoring = false
            self.lock.unlock()
            for e in replay {
                e.setIntegerValueField(.eventSourceUserData, value: FocusGuard.replayMarker)
                e.post(tap: .cghidEventTap)
            }
            if !replay.isEmpty {
                self.record("held \(replay.count) of your key events during a focus change (\(reason)) and replayed them into your app")
            }
        }
    }

    // MARK: Tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == FocusGuard.replayMarker {
            return event
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let p = event.location
            if display.isRunning && display.bounds.contains(p) {
                let q = nearestUserPoint(p)
                event.location = q
                CGWarpMouseCursorPosition(q)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            return event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lock.lock(); lastUserMouseDownMs = nowMs(); lock.unlock()
            if display.isRunning && display.bounds.contains(event.location) { return nil }
            return event
        case .scrollWheel:
            if display.isRunning && display.bounds.contains(event.location) { return nil }
            return event
        case .keyDown, .keyUp, .flagsChanged:
            if type == .keyDown {
                lock.lock()
                lastUserKeyMs = nowMs()
                if event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 48 { lastUserSwitchKeyMs = nowMs() }
                lock.unlock()
            }
            lock.lock()
            let alreadyHolding = holding
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

    private func hold(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        lock.lock()
        held.append(copy)
        lock.unlock()
    }

    private func nearestUserPoint(_ p: CGPoint) -> CGPoint {
        var best = p
        var bestDistance = CGFloat.infinity
        for id in display.userDisplayIDs() {
            let r = CGDisplayBounds(id)
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDistance { bestDistance = d; best = q }
        }
        return best
    }
}

private func guardTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let g = FocusGuard.shared else { return Unmanaged.passUnretained(event) }
    guard let out = g.handle(type: type, event: event) else { return nil }
    return Unmanaged.passUnretained(out)
}

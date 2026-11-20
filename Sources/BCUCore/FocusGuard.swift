import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CPrivate
import os

public struct GuardEvent {
    public let time: Date
    public let summary: String
}

/// Keeps the user's focus, keystrokes and cursor theirs.
///
/// - Cursor fence: mouse moves that would land on the agent display are pulled
///   back in the event tap, and a watcher thread checks the cursor every 4 ms
///   and brings it back from anything that got past the tap.
/// - Front gate: the apps agents are working in can't bring themselves to the
///   front at all while the user is elsewhere (see `FrontGate`). The gate opens
///   whenever the user does something that could switch apps; the next two
///   are for those moments, and for a macOS without the gate.
/// - Keystroke hold: if an app the agent is acting on makes itself frontmost,
///   the user's keystrokes are held, the user's app is put back in front, and
///   the keys are replayed into it. Nothing typed lands in the agent's window.
/// - Activation watch: the same restore runs when such an activation is seen
///   even without typing.
/// - Arrival: when the user switches to an app agents have windows in, its
///   key window is made theirs before their keys go on.
/// One guard for every agent display: it fences the cursor off all of them
/// and watches the front app for every session.
public final class FocusGuard {
    public var onEvent: ((GuardEvent) -> Void)?
    /// The user's recent input, for waiting until they pause (see `QuietWait`).
    public let activity = UserActivity()
    /// When the tap last saw the user move the mouse (tap thread writes,
    /// cursor watch reads).
    private let lastUserMoveMs = OSAllocatedUnfairLock(initialState: -Double.infinity)
    /// Keeps agents' apps from bringing themselves to the front (see `FrontGate`).
    public let gate = FrontGate()
    /// Called from the input tap when the user presses a key or a mouse
    /// button (not for moves or scrolls): `hook` must return at once. One
    /// per owner (a session), so that two agents with a cover up in the
    /// same app don't take away each other's; nil removes it.
    public func onUserPress(for owner: String, _ hook: (() -> Void)?) {
        pressLock.lock(); pressHooks[owner] = hook; pressLock.unlock()
    }
    private var pressHooks: [String: () -> Void] = [:]
    private let pressLock = NSLock()

    /// What the user pressed, for `onUserInput`.
    public enum UserInput {
        /// A key (not a modifier alone), going to this app.
        case key(front: pid_t)
        /// A mouse button, at this point (global, top-left origin).
        case click(at: CGPoint)
        /// Play, next, previous, fast-forward or rewind on the keyboard:
        /// it goes to whichever app last played, not to the front one.
        case mediaKey
    }
    /// Like `onUserPress`, saying what was pressed and where. Called from
    /// the input tap: `hook` must return at once. One per owner; nil removes it.
    public func onUserInput(for owner: String, _ hook: ((UserInput) -> Void)?) {
        pressLock.lock(); inputHooks[owner] = hook; pressLock.unlock()
    }
    private var inputHooks: [String: (UserInput) -> Void] = [:]

    /// Tap thread.
    private func userInput(_ type: CGEventType, _ event: CGEvent) {
        pressLock.lock(); let hooks = Array(inputHooks.values); pressLock.unlock()
        guard !hooks.isEmpty else { return }
        let input: UserInput
        if type == .keyDown {
            // cmd+Tab goes to the app switcher, not the front app.
            if event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 48 { return }
            // An agent's app that brought itself forward doesn't get the
            // key: it's held and replayed into the user's app (see `handle`).
            var front = BCUFrontProcessPID()
            let user = userFront
            if user != 0, front != user, agentCaused(front) { front = user }
            input = .key(front: front)
        } else if Self.isMouseDown(type) {
            input = .click(at: event.location)
        } else if type == Self.systemDefined, Self.isMediaKeyDown(event) {
            input = .mediaKey
        } else {
            return
        }
        for hook in hooks { hook(input) }
    }

    /// NX_SYSDEFINED: media, volume and brightness keys.
    static let systemDefined = CGEventType(rawValue: 14)!

    /// A media key going down (NX_SUBTYPE_AUX_CONTROL_BUTTONS): play (16),
    /// next (17), previous (18), fast-forward (19), rewind (20). Volume and
    /// brightness keys don't count.
    static func isMediaKeyDown(_ event: CGEvent) -> Bool {
        guard let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 else { return false }
        let code = (e.data1 & 0xFFFF_0000) >> 16
        let down = ((e.data1 & 0xFF00) >> 8) == 0xA
        return down && (16...20).contains(code)
    }

    private func userPressed() {
        pressLock.lock(); let hooks = Array(pressHooks.values); pressLock.unlock()
        for hook in hooks { hook() }
    }

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
        /// Kept from the front by the gate while tainted.
        var gated = true
    }
    private var taints: [pid_t: Taint] = [:]
    /// Apps whose key window an agent has moved to one of its windows right
    /// now (see `beginSwap`), with nesting counts.
    private var swapping: [pid_t: Int] = [:]
    private var swapSinceMs: [pid_t: Double] = [:]
    /// Apps the user isn't in whose key window was left on an agent's
    /// window after its step (see `park`).
    private var parked: [pid_t: ParkedKey] = [:]
    /// Keys the user typed into an app while it was mid-swap, held until key
    /// is back on their window. With when the first one came.
    private var pidHeld: [pid_t: (sinceMs: Double, events: [CGEvent])] = [:]
    /// Apps with agent windows the user has just switched to, with when:
    /// until the key window there is theirs (`handOver`), what they type
    /// into it is held.
    private var arriving: [pid_t: Double] = [:]
    /// Apps the user is in whose key window is an agent's and won't let go,
    /// with no window of theirs to take it (see `strand`): what they type
    /// there is held, and dropped after `maxPidHoldMs`, until that changes.
    private var stranded: Set<pid_t> = []
    /// Apps being launched for an agent, by bundle ID: kept from the front
    /// from the moment they appear, before the launch reports a pid.
    private var launching: [String: Int] = [:]
    private var userFrontPid: pid_t = 0
    /// The last regular app the user was in (see `gateTargets`).
    private var userRegularPid: pid_t = 0
    private var frontPolicy: (pid: pid_t, regular: Bool) = (0, true)
    private var secureInputSeenMs = -Double.infinity
    /// The Space each of the user's displays shows (see `spaceChanged`).
    private var shownSpaces: [CGDirectDisplayID: UInt64] = [:]
    private var userFrontWindow: CGWindowID?
    private var lastUserMouseDownMs = 0.0
    /// The user's last click: where it landed, what it was on, and the
    /// windows on their screens from just before it (id to title).
    private struct Click {
        var ms: Double
        var point: CGPoint
        /// Worked out off the event tap, right after the click (`noteClick`).
        var target: ClickTarget = .pending
        /// The window list's answer, first and fast, for when accessibility is slow.
        var fallback: ClickTarget?
        var element: ClickElement?
        var windows: [CGWindowID: String]?
    }
    private var lastClick = Click(ms: -.infinity, point: .zero, target: .app(nil))
    /// Agents' apps put back though the user had just clicked elsewhere,
    /// with when and the click: if they then go to the app themselves, the
    /// guard was probably wrong, and says so in the log.
    private var putBackOnClick: [pid_t: (ms: Double, click: Click)] = [:]
    /// Agents' apps left in front because the user had just clicked them or
    /// pressed cmd+Tab, with when and the app they were in: if they go
    /// straight back to it, the guard was probably wrong, and says so.
    private var leftOnInput: [pid_t: (ms: Double, previous: pid_t)] = [:]
    /// The windows on the user's screens, looked at every 250 ms while
    /// agents work, so a click has a look from before anything it opened.
    private var screenLook: [CGWindowID: String]?
    private let clickQueue = DispatchQueue(label: "bcu.guard.click", qos: .userInteractive)
    /// When an agent's step on each app last ended (see `Bounce`).
    private var lastActedMs: [pid_t: Double] = [:]
    private var lastUserSwitchKeyMs = 0.0
    private var lastUserKeyMs = 0.0
    /// The user's last key that could open or switch to an app: Return or
    /// Enter (a launcher, Terminal `open`, a link) or a shortcut with
    /// command, control or option held. Plain typing can't.
    private var lastUserOpenKeyMs = 0.0
    /// When the guard last put the user's app back in front of each app.
    private var restoredAwayMs: [pid_t: Double] = [:]
    /// The last few times the user came to another app (a front change that
    /// was theirs, to an app they weren't in), oldest first.
    private var arrivals: [(pid: pid_t, ms: Double)] = []
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
    /// Each user key event is captured and replayed at most once. Copies keep
    /// the event's timestamp, and every real event has its own, so a key
    /// seen twice by either path is skipped (and logged, naming the path).
    private struct KeyID: Hashable {
        let timestamp: CGEventTimestamp
        let type: UInt32
        let code: Int64
        init(_ e: CGEvent) {
            timestamp = e.timestamp
            type = e.type.rawValue
            code = e.getIntegerValueField(.keyboardEventKeycode)
        }
    }
    private var captured: [KeyID: Double] = [:]
    /// Keys whose key-down reached the app (passed or replayed) and whose
    /// key-up hasn't yet: that key-up goes straight on, never held, so a
    /// key's down and up are never split (a key held down that long is
    /// what the system and the app see, and a key-up carries no text).
    private var downDelivered: [Int64: Int] = [:]
    /// Replayed keys posted but not yet back through the tap. New user keys
    /// wait behind them: a replay goes to the back of WindowServer's queue,
    /// so a key typed meanwhile could otherwise reach the app first.
    private var replaysInFlight = 0
    private var replaysInFlightSinceMs = 0.0
    private var replayed: [KeyID: Double] = [:]
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
    /// The running guard (there is one), for the tap callback and the test tools.
    static weak var shared: FocusGuard?

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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.terminated(app.processIdentifier)
        }
        installTap()
        Thread.detachNewThread { [weak self] in self?.watchAttention() }
        Thread.detachNewThread { [weak self] in self?.watchUserScreen() }
        gate.targets = { [weak self] in self?.gateTargets() ?? FrontGate.Targets() }
        gate.tapWorking = { [weak self] in
            guard let self, let tap = self.tap, CGEvent.tapIsEnabled(tap: tap) else { return false }
            // With secure input on (a password field, Terminal's Secure
            // Keyboard Entry) macOS shows the tap no keys at all, though it
            // stays enabled: cmd+Tab and Return would never open the gate.
            // So it stays open, and a moment longer: what the password was
            // for (unlocking, an approval) is what brings an app forward.
            let now = nowMs()
            self.lock.lock(); defer { self.lock.unlock() }
            if IsSecureEventInputEnabled() { self.secureInputSeenMs = now }
            return now - self.secureInputSeenMs > Self.keyLiftMs
        }
        gate.onNote = { [weak self] note in self?.record(note) }
        gate.start()
        let spaces = Self.userSpaces()
        lock.lock(); shownSpaces = spaces; lock.unlock()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        let watcher = Thread { [weak self] in self?.watchFront() }
        watcher.name = "bcu.guard.front"
        watcher.qualityOfService = .userInteractive
        watcher.start()
        let windowWatcher = Thread { [weak self] in self?.watchUserWindow() }
        windowWatcher.name = "bcu.guard.userwindow"
        windowWatcher.qualityOfService = .utility
        windowWatcher.start()
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
                                    .keyDown, .keyUp, .flagsChanged, Self.systemDefined]
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
        let fenced = AgentDisplay.fencedBounds
        guard !fenced.isEmpty, let p = CGEvent(source: nil)?.location else { return false }
        let users = AgentDisplay.userDisplayIDs().map { CGDisplayBounds($0) }
        // An agent display lying over one of the user's (macOS wouldn't
        // place it while the screens slept): the cursor there is on their
        // screen, where it belongs. Warping it to the same spot every few
        // ms would end every hover effect under it. (The tap lets it be too.)
        guard let agent = AgentDisplay.fenced(at: p, agents: fenced, users: users) else {
            // Off every display (an event posted with a far-off location can
            // leave it there): just as invisible, and macOS only brings it
            // back when the displays change.
            if !users.contains(where: { $0.contains(p) }) {
                let q = nearestUserPoint(p, agent: .null)
                if q != p && !fenced.contains(where: { $0.contains(q) }) {
                    CGWarpMouseCursorPosition(q)
                    CGAssociateMouseAndMouseCursorPosition(1)
                    lock.lock()
                    let log = nowMs() - lastEscapeLogMs > 2000
                    if log { lastEscapeLogMs = nowMs() }
                    lock.unlock()
                    if log { Log.info("guard: cursor was off every display at \(Int(p.x)),\(Int(p.y)); moved it back to \(Int(q.x)),\(Int(q.y))") }
                }
                return true
            }
            return fenced.contains { $0.insetBy(dx: -400, dy: -400).contains(p) }
        }
        let q = returnPoint(p, agent: agent, msSinceUserMove: nowMs() - lastUserMoveMs.withLock { $0 })
        // Nowhere better to put it (no user display): leave it be.
        guard q != p, !fenced.contains(where: { $0.contains(q) }) else { return false }
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
        // Shut before the app is asked for anything, not at the gate's next look.
        if !gate.blocks(pid) { gate.sync() }
    }

    public func endAction(pid: pid_t, graceMs: Double = 700) {
        lock.lock()
        lastActedMs[pid] = nowMs()
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
        lock.lock()
        if swapping[pid] == nil { swapSinceMs[pid] = nowMs() }
        swapping[pid, default: 0] += 1
        lock.unlock()
    }

    public func endSwap(_ pid: pid_t) {
        lock.lock()
        if let n = swapping[pid] { swapping[pid] = n > 1 ? n - 1 : nil }
        let done = swapping[pid] == nil
        let since = done ? swapSinceMs.removeValue(forKey: pid) : nil
        let waiting = pidHeld[pid]?.events.count ?? 0
        lock.unlock()
        if done {
            // What the user felt of it: how long anything they typed into the app waited.
            if waiting > 0, let since { Log.info("guard: key was away from the user's window in pid \(pid) for \(Int(nowMs() - since)) ms; \(waiting) of their key events waited") }
            releasePidHeld(pid)
        }
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

    /// The user asked to switch apps from BCU's own UI (opening a window an
    /// agent handed them), so the activation that follows is theirs.
    public func noteUserSwitch() {
        lock.lock(); lastUserSwitchKeyMs = nowMs(); lock.unlock()
        gate.lift(ms: Self.keyLiftMs)
    }

    /// True when the user recently clicked or switched apps, so an activation
    /// right now is theirs.
    func userCausedRecently(withinMs: Double = 400) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        return now - lastUserMouseDownMs < withinMs || now - lastUserSwitchKeyMs < withinMs
    }

    func debugCause(_ pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs()
        let until = taints[pid].map { $0.count > 0 ? "running" : "\(Int($0.until - now))ms left" } ?? "none"
        let restored = restoredAwayMs[pid].map { " restored=\(Int(now - $0))ms" } ?? ""
        return "taint=\(until) key=\(Int(now - lastUserKeyMs))ms openKey=\(Int(now - lastUserOpenKeyMs))ms click=\(Int(now - lastUserMouseDownMs))ms clickOn=\(Self.describe(lastClick))\(restored)"
    }

    /// Where a click landed and on what, for the log: "TextEdit (AXButton)",
    /// "Dock: Helium", "pending".
    private static func describe(_ c: Click) -> String {
        let name = { (p: pid_t) in NSRunningApplication(processIdentifier: p)?.localizedName ?? "pid \(p)" }
        let what: String
        switch c.target {
        case .pending: what = "pending"
        case .app(let p): what = p.map(name) ?? "nothing"
        case .dock(let p): what = "Dock: " + (p.map { $0 == 0 ? "not running" : name($0) } ?? "unknown")
        }
        switch c.element {
        case .link: return what + " (link)"
        case .other(let role): return what + " (\(role))"
        case .unknown: return what + " (unknown)"
        case nil: return what
        }
    }

    /// Whether `pid` becoming frontmost right now is the agent's doing
    /// (the rule is `Attribution.agentCaused`): yes while an action on it is
    /// running or in its grace period, or just after the guard put the
    /// user's app back in front of it, unless the user clicked or pressed
    /// cmd+Tab and hasn't come to another app since.
    func agentCaused(_ pid: pid_t) -> Bool {
        Attribution.agentCaused(facts(pid))
    }

    private func facts(_ pid: pid_t) -> Attribution.Facts {
        lock.lock(); defer { lock.unlock() }
        return Attribution.Facts(
            nowMs: nowMs(),
            step: taints[pid].map { Attribution.Step(running: $0.count, settleUntilMs: $0.until, strict: $0.strict) },
            restoredAwayMs: restoredAwayMs[pid],
            lastMouseDownMs: lastUserMouseDownMs, lastSwitchKeyMs: lastUserSwitchKeyMs, lastOpenKeyMs: lastUserOpenKeyMs,
            arrivedElsewhereMs: arrivals.last(where: { $0.pid != pid })?.ms ?? -.infinity,
            clickOnApp: lastClick.target.explains(pid))
    }

    /// Where the user's last click landed is worked out just after it, off
    /// the event tap. Before deciding whether a click explains an app
    /// coming forward, wait for that (50 ms at most; accessibility is
    /// usually back in a few). Still not known: the window list's answer,
    /// else nothing known, which explains no app.
    private func settleClick() {
        let deadline = nowMs() + 50
        while true {
            lock.lock()
            let c = lastClick
            if c.target != .pending || nowMs() - c.ms >= Attribution.switchMs { lock.unlock(); return }
            if nowMs() >= deadline {
                lastClick.target = c.fallback ?? .app(nil)
                lock.unlock()
                Log.info("guard: where your click landed took over 50 ms to work out; going by \(Self.describe(lastClick))")
                return
            }
            lock.unlock()
            usleep(2000)
        }
    }

    /// What's under a click at `p` (global, top-left origin), asked of
    /// accessibility, which skips windows clicks pass through, then up
    /// through its parents: the app, the Dock icon's app, and whether it's
    /// a link. Without accessibility, the window list's answer (`listed`).
    private static func whatWasClicked(at p: CGPoint, listed: ClickTarget) -> (ClickTarget, ClickElement?) {
        func isDock(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let hit,
              AXUIElementGetPid(hit, &pid) == .success, pid > 0 else {
            return (listed, nil)
        }
        var roles: [String] = []
        var url = false
        var element: AXUIElement? = hit
        // Each ask can take the full timeout in a busy app: 300 ms in all,
        // then what's known so far.
        let deadline = nowMs() + 300
        for _ in 0..<8 {
            guard let el = element, nowMs() < deadline else { break }
            AXUIElementSetMessagingTimeout(el, 0.25)
            let role = AX.string(el, "AXRole") ?? ""
            roles.append(role)
            if role == "AXDockItem" {
                guard let link = AX.attr(el, "AXURL") as? URL else { return (.dock(nil), nil) }
                let path = link.standardizedFileURL.path
                let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
                return (.dock(app?.processIdentifier ?? 0), nil)
            }
            if AX.attr(el, "AXURL") != nil { url = true }
            if role == "AXWindow" || role == "AXApplication" { break }
            element = AX.element(el, "AXParent")
        }
        if isDock(pid) { return (.dock(nil), nil) }
        return (.app(pid), ClickElement.classify(roles: roles, url: url))
    }

    /// An agent's app was put back though the user had just clicked
    /// elsewhere (`click`). If the click opened something there after all (a
    /// link in their chat app, opening in the browser an agent works in),
    /// bring the app forward with it once it shows (`LateLook`).
    private func lookLate(at pid: pid_t, click: Click, putBackMs: Double) {
        let name = { (p: pid_t) in NSRunningApplication(processIdentifier: p)?.localizedName ?? "pid \(p)" }
        DispatchQueue.global(qos: .userInitiated).async {
            while nowMs() - click.ms < LateLook.forMs {
                sleepMs(LateLook.everyMs)
                self.lock.lock()
                let now = self.lastClick.ms == click.ms ? self.lastClick : click
                let inputSince = LateLook.inputSince(clickMs: click.ms, putBackMs: putBackMs, mouseDownMs: self.lastUserMouseDownMs, keyMs: self.lastUserKeyMs)
                self.lock.unlock()
                guard LateLook.wanted(now.element) else { return }
                let mine = Dictionary(WindowList.of(pid: pid, onScreenOnly: true)
                    .filter { $0.layer == 0 && !Self.onAgentDisplay($0.id) }.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                let front = BCUFrontProcessPID() == pid
                let facts = LateLook.Facts(front: front, inputSince: inputSince, opened: LateLook.opened(before: now.windows, now: mine))
                guard let window = LateLook.bringForward(facts) else {
                    if front || inputSince { return }
                    continue
                }
                self.lock.lock(); self.putBackOnClick[pid] = nil; self.lock.unlock()
                // Theirs: the switch the guard makes for them counts as their cmd+Tab.
                self.noteUserSwitch()
                _ = BCUSetFrontProcess(pid, window, 0x200)
                self.record("\(name(pid)) opened something from your click \(Int(nowMs() - click.ms)) ms ago in \(Self.describe(now)); brought it forward")
                return
            }
        }
    }

    /// The user's windows on their screens: id to title.
    private static func userScreenWindows() -> [CGWindowID: String] {
        var out: [CGWindowID: String] = [:]
        for w in WindowList.all(onScreenOnly: true) where w.layer == 0 && !onAgentDisplay(w.id) { out[w.id] = w.title }
        return out
    }

    /// When the user last clicked or pressed a key that could open a window
    /// (Return, or a key with command, control or option held).
    var lastUserOpenInputMs: Double {
        lock.lock(); defer { lock.unlock() }
        return max(lastUserOpenKeyMs, lastUserMouseDownMs)
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
        // While the answer is on its way a restore still needs a window to
        // raise: keep the last one known for this app.
        if userFrontPid != pid { userFrontWindow = nil }
        userFrontPid = pid
        lock.unlock()
        if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
            lock.lock(); userRegularPid = pid; lock.unlock()
        }
        var window = AX.focusedWindowID(pid)
        if let w = window, Self.onAgentDisplay(w) { window = nil }
        lock.lock()
        guard userFrontPid == pid else { lock.unlock(); return }
        if window != nil { userFrontWindow = window }
        lock.unlock()
    }

    /// An app quit. If it was the user's, a restore would put a pid that's
    /// gone back in front, and keys would wait on it: whichever app macOS
    /// brings forward in its place is theirs now.
    private func terminated(_ pid: pid_t) {
        lock.lock()
        taints[pid] = nil
        parked[pid] = nil
        arriving[pid] = nil
        stranded.remove(pid)
        restoredAwayMs[pid] = nil
        if Self.dropsHeldOnQuit(swapping: swapping[pid] != nil) { pidHeld[pid] = nil }
        if userRegularPid == pid { userRegularPid = 0 }
        let wasUsers = userFrontPid == pid
        if wasUsers { userFrontPid = 0; userFrontWindow = nil }
        lock.unlock()
        guard wasUsers else { return }
        DispatchQueue.global(qos: .userInteractive).async {
            let deadline = nowMs() + 500
            var front = BCUFrontProcessPID()
            while (front == 0 || front == pid) && nowMs() < deadline { sleepMs(5); front = BCUFrontProcessPID() }
            guard front != 0, front != pid, front != getpid() else { return }
            Log.info("guard: the user's app (pid \(pid)) quit; pid \(front) is theirs now")
            self.arrived(front)
        }
    }

    /// Whether keys held for an app that quit are dropped: always, even
    /// while a swap in it unwinds, or its end would replay them into the
    /// app the user is in next.
    static func dropsHeldOnQuit(swapping: Bool) -> Bool {
        true
    }

    // MARK: Front watch

    /// One change of the front app, for the report each tool call gives.
    private struct FrontChange {
        let seq: Int
        let ms: Double
        let pid: pid_t
        /// An agent's app that put itself there.
        let agent: Bool
    }
    private var frontLog: [FrontChange] = []
    private var frontSeq = 0
    private let arriveQueue = DispatchQueue(label: "bcu.guard.arrive", qos: .userInteractive)

    /// Samples the front app (WindowServer's own view) for as long as the
    /// guard runs: every millisecond while agents have windows or an action
    /// is in its grace period, every 20 ms otherwise. An agent's app that
    /// got to the front is sent back from here rather than on NSWorkspace's
    /// notification, which comes about 25 ms later; when it's the user who
    /// came to an app, its key window is sorted out (`arrived`).
    private func watchFront() {
        var last = BCUFrontProcessPID()
        var n = 0
        var fast = false
        while true {
            let pid = BCUFrontProcessPID()
            if pid != 0 && pid != last {
                last = pid
                frontChanged(to: pid)
            }
            if n % 20 == 0 { fast = !WindowManager.agentPids().isEmpty || !activeTaints.isEmpty }
            n &+= 1
            usleep(fast ? 1000 : 20_000)
        }
    }

    /// Cancel attention requests (a bouncing Dock icon) from apps agents are
    /// working in, when they're the agents' doing (`Bounce.quiet`). Looks
    /// every 100 ms while agents have windows, every 10 ms during and just
    /// after a step.
    private func watchAttention() {
        var noted: Set<pid_t> = []
        while true {
            let pids = WindowManager.agentPids()
            if pids.isEmpty {
                noted.removeAll()
                usleep(500_000)
                continue
            }
            let front = BCUFrontProcessPID()
            for pid in pids where BCUAppWantsAttention(pid) == 1 {
                lock.lock()
                let since = lastActedMs[pid].map { nowMs() - $0 }
                let running = (taints[pid]?.count ?? 0) > 0
                lock.unlock()
                let userWindows = WindowList.of(pid: pid, onScreenOnly: true).filter { $0.layer == 0 && !Self.onAgentDisplay($0.id) }.count
                guard Bounce.quiet(userInApp: front == pid, agentApp: true, sinceStepMs: running ? 0 : since, userWindows: userWindows) else { continue }
                let status = BCUClearAppAttention(pid)
                if !noted.contains(pid) {
                    noted.insert(pid)
                    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                    record("\(name) asked for attention (its Dock icon bounced) after an agent's step; \(status == 0 ? "cancelled it" : "COULD NOT cancel it (status \(status))")")
                }
            }
            // Right after a step (when apps ask) look every 10 ms: the Dock
            // starts coming up as soon as it hears of the request.
            lock.lock()
            let now = nowMs()
            let hot = pids.contains { (taints[$0]?.count ?? 0) > 0 || now - (lastActedMs[$0] ?? -.infinity) < 3000 }
            lock.unlock()
            usleep(hot ? 10_000 : 100_000)
        }
    }

    /// The user can move between windows of the app they're in without the
    /// app changing, and a restore that raised the window they were in when
    /// they arrived would bring the wrong one forward. Ask every 300 ms
    /// while agents are at work (its own thread: the app may be slow to answer).
    private func watchUserWindow() {
        while true {
            usleep(300_000)
            refreshSystemShortcuts()
            checkStranded()
            guard !WindowManager.agentPids().isEmpty || !activeTaints.isEmpty else { continue }
            let front = BCUFrontProcessPID()
            lock.lock()
            let mine = front != 0 && front == userFrontPid && swapping[front] == nil && arriving[front] == nil
            lock.unlock()
            guard mine else { continue }
            let app = AXUIElementCreateApplication(front)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let w = AX.element(app, "AXFocusedWindow"), let id = AX.windowID(w), !Self.onAgentDisplay(id) else { continue }
            lock.lock()
            if userFrontPid == front && swapping[front] == nil { userFrontWindow = id }
            lock.unlock()
        }
    }

    private func frontChanged(to pid: pid_t) {
        if pid != getpid() { settleClick() }
        let f = facts(pid)
        let user = userFront
        let agent = pid != getpid() && pid != user && Attribution.agentCaused(f)
        lock.lock()
        frontSeq += 1
        frontLog.append(FrontChange(seq: frontSeq, ms: nowMs(), pid: pid, agent: agent))
        if frontLog.count > 400 { frontLog.removeFirst(frontLog.count - 400) }
        lock.unlock()
        if agent {
            restoreUserFront(from: pid, reason: "self-activation", immediate: true)
            notePutBack(pid, f)
        } else if pid != getpid() {
            // Left in front during an agent's step because of their click on
            // it or their cmd+Tab: if they go straight back, say so (`arrived`).
            if Attribution.acting(f) && pid != user && user != 0 {
                lock.lock(); leftOnInput[pid] = (f.nowMs, user); lock.unlock()
            }
            arrived(pid)
        }
    }

    /// The guard put `pid` back. If the user had just clicked somewhere
    /// else, log it, and look a while for what the click may have opened
    /// there (`lookLate`). Once per click: Chromium often comes forward twice.
    private func notePutBack(_ pid: pid_t, _ f: Attribution.Facts) {
        lock.lock()
        let c = lastClick
        let recent = f.nowMs - c.ms < Attribution.switchMs && c.ms > f.arrivedElsewhereMs
        let seen = putBackOnClick[pid]?.click.ms == c.ms
        if recent && !seen { putBackOnClick[pid] = (f.nowMs, c) }
        lock.unlock()
        guard recent, !seen else { return }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        Log.info("guard: put \(name) back though you clicked \(Int(f.nowMs - c.ms)) ms before, in \(Self.describe(c))")
        lookLate(at: pid, click: c, putBackMs: f.nowMs)
    }

    /// Where the record of front-app changes stands; pass it to `frontReport` later.
    public var frontMark: Int {
        lock.lock(); defer { lock.unlock() }
        return frontSeq
    }

    /// What `apps` (the ones an agent is working in) did to the user's front
    /// app since `mark`, or nil if nothing: each time one of them was in
    /// front and for how long. Changes the user made themselves aren't news.
    public func frontReport(since mark: Int, apps: Set<pid_t>) -> String? {
        lock.lock()
        let log = frontLog
        lock.unlock()
        let mine = log.indices.filter { log[$0].seq > mark && log[$0].agent && apps.contains(log[$0].pid) }
        guard !mine.isEmpty else { return nil }
        func name(_ pid: pid_t) -> String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }
        let now = nowMs()
        let parts = mine.map { i -> String in
            let end = i + 1 < log.count ? log[i + 1].ms : now
            return "\(name(log[i].pid)) was frontmost for \(Int(end - log[i].ms)) ms"
        }
        // WindowServer names no front process for a moment while apps
        // switch (and while the screen is locked): go by the last one it named.
        var front = BCUFrontProcessPID()
        if front == 0 { front = log.last(where: { $0.pid != 0 })?.pid ?? 0 }
        let still = mine.last == log.count - 1 && front == log[log.count - 1].pid
        return "Front app changed: " + parts.joined(separator: "; ")
            + (still ? ", and is STILL in front" : front == 0 ? ", then it left the front" : ", then the user's app (\(name(front))) was back in front")
    }

    /// The user came to `pid`: they switched to it, it wasn't an agent's doing.
    private func arrived(_ pid: pid_t) {
        let agentApp = parkedKey(pid) != nil || WindowManager.agentPids().contains(pid)
        let now = nowMs()
        lock.lock()
        // Where the guard was probably wrong: they went to an app it had
        // just put back, or straight back from one it had left in front.
        let putBack = putBackOnClick.removeValue(forKey: pid)
        let wentBack = leftOnInput.filter { $0.value.previous == pid && now - $0.value.ms < 3000 }
        leftOnInput = leftOnInput.filter { $0.value.previous != pid && now - $0.value.ms < 3000 }
        putBackOnClick = putBackOnClick.filter { now - $0.value.ms < 5000 }
        let known = userFrontPid == pid
        // (Once per arrival: NSWorkspace's word of the same change comes here too.)
        if !known, arrivals.last?.pid != pid {
            arrivals.append((pid, nowMs()))
            if arrivals.count > 4 { arrivals.removeFirst(arrivals.count - 4) }
        }
        if agentApp { arriving[pid] = nowMs() }
        lock.unlock()
        let name = { (p: pid_t) in NSRunningApplication(processIdentifier: p)?.localizedName ?? "pid \(p)" }
        if let putBack, now - putBack.ms < 5000 {
            Log.info("guard: probably wrong: you went to \(name(pid)) yourself \(Int(now - putBack.ms)) ms after it was put back on your click in \(Self.describe(putBack.click))")
        }
        for (app, left) in wentBack {
            Log.info("guard: probably wrong: \(name(app)) was left in front on your click or cmd+Tab, and you went back to \(name(pid)) after \(Int(now - left.ms)) ms")
        }
        if agentApp {
            arriveQueue.async {
                self.handOver(pid)
                self.lock.lock(); self.arriving[pid] = nil; self.lock.unlock()
                self.releasePidHeld(pid)
            }
        }
        // Off this thread: accessibility calls into a busy app can take a second.
        if !known || agentApp {
            DispatchQueue.global(qos: .userInitiated).async { self.noteUserFront(pid) }
        }
    }

    /// The user is in `pid` now, where agents have windows. If one of those
    /// is its key window (left so after a step, or made key by AppKit on
    /// activation as the one that had key last), their typing would go
    /// somewhere they can't see. Key goes to their window; what they type
    /// meanwhile is held (`arriving`) and replayed once it has.
    private func handOver(_ pid: pid_t) {
        let t0 = nowMs()
        // A step in this app holds its lock while its window has key; seeing
        // the user there it stops, and hands key back itself.
        let appLock = Engine.inputLock(pid)
        let locked = appLock.lock(before: Date().addingTimeInterval(Self.maxHoldMs / 1000))
        defer { if locked { appLock.unlock() } }
        lock.lock()
        let was = parked.removeValue(forKey: pid)
        lock.unlock()
        guard BCUFrontProcessPID() == pid, !isSwapping(pid) else { return }
        let moved = reclaimKey(pid)
        // No window of theirs to take key: at least not the agent's.
        if let was, AX.focusedWindowID(pid) == was.keyWindow { _ = BCUPostFocusRecord(pid, was.keyWindow, false) }
        if moved || was != nil {
            Log.info("guard: the user came to pid \(pid), where an agent's window had key; sorted out in \(Int(nowMs() - t0)) ms")
        }
    }

    /// The user moved to another Space. If the app whose window is in front
    /// there is one the gate was keeping back, macOS couldn't bring it
    /// forward: do that for them.
    private func spaceChanged() {
        // Adding or removing a display posts this too. Nothing to do then,
        // and the gate stays shut: bringing forward whatever window is on
        // top would hand the keyboard to an app the user wasn't in.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(60)) {
            // A real switch: one of the user's displays shows another Space
            // than it did. (Where macOS won't say, any of these counts.)
            let now = Self.userSpaces()
            self.lock.lock()
            let before = self.shownSpaces
            self.shownSpaces = now
            self.lock.unlock()
            let known = now.values.contains { $0 != 0 }
            let switched = now.contains { id, space in space != 0 && before[id] != nil && before[id] != space }
            guard switched || !known else { return }
            let front = BCUFrontProcessPID()
            let agents = AgentDisplay.running.map(\.liveBounds)
            let onScreen = WindowList.all(onScreenOnly: true).filter { w in
                w.layer == 0 && w.alpha > 0 && w.bounds.width > 100 && w.bounds.height > 100 && !agents.contains { $0.intersects(w.bounds) }
            }
            guard let top = onScreen.first, top.pid != front, top.pid != getpid(),
                  !onScreen.contains(where: { $0.pid == front }), WindowManager.agentPids().contains(top.pid) else { return }
            self.noteUserSwitch()
            _ = BCUSetFrontProcess(top.pid, top.id, 0x200)
            let deadline = nowMs() + 300
            while BCUFrontProcessPID() != top.pid && nowMs() < deadline { sleepMs(2) }
            sleepMs(Self.activationSettleMs)
            _ = BCUPostMakeKeyRecords(top.pid, top.id)
            self.record("you moved to a Space where \(top.owner) is in front; brought it forward")
        }
    }

    /// The Space on each of the user's displays (0 where macOS won't say).
    private static func userSpaces() -> [CGDirectDisplayID: UInt64] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [:] }
        let agents = Set(AgentDisplay.running.map(\.displayID))
        var out: [CGDirectDisplayID: UInt64] = [:]
        for id in ids.prefix(Int(n)) where !agents.contains(id) { out[id] = BCUCurrentSpaceForDisplay(id) }
        return out
    }

    /// What the gate keeps from the front: the apps agents have windows in
    /// or are acting on. (It leaves out whichever is in front itself.)
    private func gateTargets() -> FrontGate.Targets {
        var pids = WindowManager.agentPids()
        // Whether what's in front is an ordinary app (asked only when it changes).
        let front = BCUFrontProcessPID()
        lock.lock()
        var policy = frontPolicy
        lock.unlock()
        if policy.pid != front {
            policy = (front, front == 0 || NSRunningApplication(processIdentifier: front)?.activationPolicy == .regular)
        }
        lock.lock()
        frontPolicy = policy
        let now = nowMs()
        var stepping = Set<pid_t>()
        for (pid, t) in taints where t.gated && (t.count > 0 || t.until >= now) {
            pids.insert(pid)
            if t.count > 0 { stepping.insert(pid) }
        }
        let bundles = Set(launching.keys)
        // Never the app the user is in, when agents have windows in it too:
        // the gate leaves out whichever app is in front, but theirs isn't
        // for a moment each time something of the system's is (the lock
        // screen, the screen saver, a Touch ID or password sheet). macOS
        // gives it the front back by itself afterwards, with no click or key
        // for the tap to open the gate on, and would be refused.
        pids.remove(userFrontPid)
        if !policy.regular { pids.remove(userRegularPid) }
        lock.unlock()
        return FrontGate.Targets(pids: pids, bundleIDs: bundles, stepping: stepping.intersection(pids))
    }

    /// An app is about to be launched for an agent: keep it from the front
    /// from the moment it appears. Pair with `launched`.
    public func willLaunch(bundleID: String) {
        lock.lock(); launching[bundleID, default: 0] += 1; lock.unlock()
        gate.sync()
    }

    public func launched(bundleID: String) {
        lock.lock()
        if let n = launching[bundleID] { launching[bundleID] = n > 1 ? n - 1 : nil }
        lock.unlock()
    }

    /// NSWorkspace's word that an app became active, about 25 ms after the
    /// front watch saw it: the backup for both of its jobs. Right after a
    /// click whose target isn't known yet, it waits for that off the main
    /// thread, so both decide alike.
    private func activated(_ app: NSRunningApplication) {
        lock.lock()
        let pending = lastClick.target == .pending && nowMs() - lastClick.ms < Attribution.switchMs
        lock.unlock()
        guard pending else { return handleActivated(app) }
        DispatchQueue.global(qos: .userInteractive).async {
            self.settleClick()
            self.handleActivated(app)
        }
    }

    private func handleActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        Log.info("guard: activated \(app.localizedName ?? "?") pid \(pid) tainted=\(isTainted(pid)) userFront=\(userFront) agentCaused=\(agentCaused(pid)) \(debugCause(pid))")
        if pid == getpid() { return }
        if agentCaused(pid) && pid != userFront {
            if BCUFrontProcessPID() == pid { restoreUserFront(from: pid, reason: "activation") }
        } else if BCUFrontProcessPID() == pid {
            lock.lock()
            let handled = userFrontPid == pid || arriving[pid] != nil
            lock.unlock()
            if !handled { arrived(pid) }
        }
    }

    static func onAgentDisplay(_ id: CGWindowID) -> Bool {
        guard let info = WindowList.info(id) else { return false }
        return AgentDisplay.running.contains { $0.liveBounds.intersects(info.bounds) }
    }

    // MARK: Parked key

    public struct ParkedKey {
        public let window: CGWindowID
        /// The window that has key: `window`, or the sheet over it.
        public var keyWindow: CGWindowID
        /// The agent session whose window it is.
        public let owner: String
        /// When that agent last did anything in the window.
        public var lastUsedMs: Double
    }

    /// Leave key on the agent's window after its step, in an app the user
    /// isn't in. Giving it up would blur the page: a web form takes that as
    /// leaving the field (a dropdown closes, a combobox clears what was
    /// typed), so the agent's next step would find it reset. The user always
    /// comes first: keys they type into the app are held from the moment
    /// they switch to it until key is on their window (`activated`).
    public func park(_ pid: pid_t, window: CGWindowID, keyWindow: CGWindowID? = nil, owner: String) {
        lock.lock()
        parked[pid] = ParkedKey(window: window, keyWindow: keyWindow ?? window, owner: owner, lastUsedMs: nowMs())
        lock.unlock()
    }

    public func parkedKey(_ pid: pid_t) -> ParkedKey? {
        lock.lock(); defer { lock.unlock() }
        return parked[pid]
    }

    /// The agent did something in this window: if it holds its app's key,
    /// it keeps it a while longer before another agent may take it.
    public func touchParked(window: CGWindowID) {
        lock.lock()
        for (pid, p) in parked where p.window == window { parked[pid]?.lastUsedMs = nowMs() }
        lock.unlock()
    }

    /// An agent took key from this app's parked window (or gave it back).
    public func forgetParked(_ pid: pid_t) {
        lock.lock(); parked[pid] = nil; lock.unlock()
    }

    /// Stop holding key on an agent window in `pid`. If the user is in the
    /// app, key goes to their window; otherwise the agent's window resigns
    /// it so the app counts itself inactive again. Then the user's held keys
    /// for the app go on. `window`: only if that's the parked one.
    public func unpark(_ pid: pid_t, window: CGWindowID? = nil, reason: String) {
        let appLock = Engine.inputLock(pid)
        appLock.lock()
        defer { appLock.unlock() }
        lock.lock()
        guard let p = parked[pid], window == nil || p.window == window else { lock.unlock(); return }
        parked[pid] = nil
        lock.unlock()
        if !isSwapping(pid) {
            if BCUFrontProcessPID() == pid {
                reclaimKey(pid)
                // No window of theirs to take key: at least not the agent's.
                if AX.focusedWindowID(pid) == p.keyWindow { _ = BCUPostFocusRecord(pid, p.keyWindow, false) }
            } else if AX.focusedWindowID(pid) == p.keyWindow {
                _ = BCUPostFocusRecord(pid, p.keyWindow, false)
            }
        }
        Log.info("guard: gave up key on agent window \(p.window) in pid \(pid): \(reason)")
        releasePidHeld(pid)
    }

    /// `reclaimKey`, but never in the middle of a key swap: a swap in this
    /// app, from any session, holds the app's input lock from before it
    /// moves key until key is back, so taking the lock waits for it to end.
    public func reclaimWhenSafe(_ pid: pid_t) {
        let appLock = Engine.inputLock(pid)
        appLock.lock()
        defer { appLock.unlock() }
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
            let bounds = WindowList.info(key)?.bounds ?? .zero
            if Self.strandsKey(bounds: bounds, agents: AgentDisplay.running.map(\.liveBounds),
                               users: AgentDisplay.userDisplayIDs().map { CGDisplayBounds($0) }) {
                strand(pid, key: key, name: name)
            } else {
                record("\(name) was in front with key window \(key) where an agent display lies over one of the user's; left it, as it's on their screen")
            }
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

    /// Whether a key window with these bounds is an agent's to take key
    /// off (`strand`): its center is on an agent display and not on a user
    /// display lying over it, by the cursor fence's rule.
    static func strandsKey(bounds: CGRect, agents: [CGRect], users: [CGRect]) -> Bool {
        AgentDisplay.fenced(at: CGPoint(x: bounds.midX, y: bounds.midY), agents: agents, users: users) != nil
    }

    /// The user is in `pid` with an agent's window as its key window and no
    /// window of theirs to give key to: the app's only windows are agents'
    /// (they cmd+Tabbed to it, or clicked it in the Dock), or they lent an
    /// agent their only one. Take key off the agent's window: with no key
    /// window, typing goes nowhere and the app's menus still take shortcuts
    /// (cmd+N opens them a window). If it won't let go, their keys for the
    /// app are held (`stranded`) rather than typed into the agent's window.
    private func strand(_ pid: pid_t, key: CGWindowID, name: String) {
        // Not the user's doing: the restore that's under way deals with it.
        guard !agentCaused(pid) else {
            record("\(name) was in front with an agent window (\(key)) as its key window; COULD NOT give key back: no window of the user's on their screens")
            return
        }
        _ = BCUPostFocusRecord(pid, key, false)
        let deadline = nowMs() + 250
        while AX.focusedWindowID(pid) == key && nowMs() < deadline { sleepMs(2) }
        let off = AX.focusedWindowID(pid) != key
        lock.lock()
        let fresh = !off && stranded.insert(pid).inserted
        lock.unlock()
        if off {
            record("\(name) was in front with an agent window (\(key)) as its key window and no window of the user's on their screens; took key off it")
        } else if fresh {
            record("\(name) was in front with an agent window (\(key)) as its key window and no window of the user's on their screens; COULD NOT take key off it, so your keys for it are held until a window of yours has key")
        }
    }

    /// Every 300 ms: a stranded app's keys go on once its key window isn't
    /// an agent's (the user opened a window, say), and are dropped once
    /// the user has left it.
    private func checkStranded() {
        lock.lock(); let pids = stranded; lock.unlock()
        guard !pids.isEmpty else { return }
        let front = BCUFrontProcessPID()
        for pid in pids {
            var safe = false
            var frontAfter = front
            if pid == front {
                let appLock = Engine.inputLock(pid)
                guard appLock.lock(before: Date().addingTimeInterval(0.05)) else { continue }
                if !isSwapping(pid) { reclaimKey(pid) }
                appLock.unlock()
                safe = keySafe(pid)
                frontAfter = BCUFrontProcessPID()
            }
            lock.lock()
            let outcome = Self.strandedOutcome(pid: pid, frontBefore: front, frontAfter: frontAfter, keySafe: safe, swapping: swapping[pid] != nil)
            if outcome != .wait { stranded.remove(pid) }
            let dropped = outcome == .drop ? pidHeld.removeValue(forKey: pid)?.events.count ?? 0 : 0
            lock.unlock()
            if dropped > 0 {
                record("dropped \(dropped) of your key events typed into pid \(pid) while an agent's window had key there, rather than type them into it")
            }
            if outcome == .release { releasePidHeld(pid) }
        }
    }

    /// What `checkStranded` does with a stranded app's held keys.
    enum StrandedOutcome: Equatable {
        /// Still stranded: keep holding them.
        case wait
        /// A window of the user's has key: send them on.
        case release
        /// The user left the app: drop them, even mid-swap (the swap's
        /// end would replay them into the app they're in now).
        case drop
    }

    /// `frontBefore` and `frontAfter`: the front app before and after the
    /// accessibility calls that tried to give key back (they can take a
    /// second); `keySafe` is from those calls.
    static func strandedOutcome(pid: pid_t, frontBefore: pid_t, frontAfter: pid_t, keySafe: Bool, swapping: Bool) -> StrandedOutcome {
        if pid != frontBefore || pid != frontAfter { return .drop }
        return keySafe ? .release : .wait
    }

    /// The window of `pid` the user would expect to be key: a standard
    /// window on their screens (not a popup, tooltip or suggestion list).
    /// `prefer` if given (the caller saw it key just now), else the one in
    /// front on their screens, which is the one they're in. The window they
    /// were in when they came to the app is only a last resort: they may
    /// have moved to another of its windows since, and handing key to that
    /// one sends their typing to a window behind the one they're looking at.
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
        let candidates = [prefer].compactMap { $0 } + onScreen.map(\.id) + [last].compactMap { $0 }
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
    func restoreUserFront(from agent: pid_t, reason: String, immediate: Bool = false, again: Bool = false) {
        lock.lock()
        if restoring { lock.unlock(); return }
        restoring = true
        let pid = userFrontPid
        let window = userFrontWindow ?? 0
        if agent != 0 && agent != pid {
            restoredAwayMs = restoredAwayMs.filter { nowMs() - $0.value < 5000 }
            restoredAwayMs[agent] = nowMs()
        }
        lock.unlock()

        let t0 = nowMs()
        var status: Int32 = 0
        if immediate && pid != 0 { status = BCUSetFrontProcess(pid, window, 0x200) }
        let t1 = nowMs()

        restoreQueue.async {
            if pid != 0 {
                if !immediate { status = BCUSetFrontProcess(pid, window, 0x200) }
                let deadline = nowMs() + 500
                var lastCall = nowMs()
                while BCUFrontProcessPID() != pid && nowMs() < deadline {
                    // An app that activates again while the first call lands
                    // (Chromium does, opening a window) keeps the front until
                    // asked again. Only while it's still the agent's app in
                    // front: an app the user switched to is left alone.
                    if agent != 0 && BCUFrontProcessPID() == agent && nowMs() - lastCall >= 20 {
                        status = BCUSetFrontProcess(pid, window, 0x200)
                        lastCall = nowMs()
                    }
                    sleepMs(1)
                }
                Log.info("guard: restore (\(reason)) setFront=\(status) call \(Int(t1 - t0)) ms, front back after \(Int(nowMs() - t0)) ms")
                if BCUFrontProcessPID() == pid {
                    self.makeKeyAgain(pid, window: CGWindowID(window))
                    self.uncover(pid, window: CGWindowID(window), from: agent)
                }
            }
            self.lock.lock()
            self.holding = false
            self.restoring = false
            self.lock.unlock()
            // The app may have taken the front again meanwhile (Chromium often
            // does it twice), when a restore was already under way.
            let front = BCUFrontProcessPID()
            if !again && pid != 0 && front != 0 && front != pid && front != getpid() && self.agentCaused(front) {
                self.restoreUserFront(from: front, reason: "\(reason), again", immediate: true, again: true)
                return
            }
            let n = self.drain()
            if n > 0 { self.record("held \(n) of your key events during a focus change (\(reason)) and replayed them into your app") }
        }
    }

    /// How long an app takes to see that it's active again once it's in front.
    static let activationSettleMs = 30.0

    /// Being in front again doesn't give the user's app a key window: it
    /// comes back active with none, its window drawn inactive (grey title
    /// bar, lighter shadow) though their typing still reaches it. The make-key
    /// records give it one, but only once the app knows it's active: if they
    /// get there first (the other app took the front twice, say), it ends up
    /// the same way. So: after it's in front, and after a moment. Not while
    /// an agent's window is key there for a swap, which gives key back itself.
    private func makeKeyAgain(_ pid: pid_t, window: CGWindowID) {
        sleepMs(Self.activationSettleMs)
        guard BCUFrontProcessPID() == pid, !isSwapping(pid) else { return }
        // Not known (the app was busy when asked): accessibility names the
        // window that would be key.
        var id = window != 0 ? window : (AX.focusedWindowID(pid) ?? 0)
        if id != 0, Self.onAgentDisplay(id) { id = userWindow(of: pid) ?? 0 }
        if id != 0 { _ = BCUPostMakeKeyRecords(pid, id) }
    }

    /// An app that put itself in front brought windows forward with it, and
    /// giving the front back doesn't send them behind again: one of them can
    /// stay on top of the user's window, on their screen, with their app in
    /// front (so cmd+Tab shows nothing wrong). Raise the user's window back
    /// over it; their app is in front, so nothing else moves.
    private func uncover(_ pid: pid_t, window: CGWindowID, from intruder: pid_t) {
        guard intruder != 0, intruder != pid else { return }
        let id = window != 0 ? window : (AX.focusedWindowID(pid) ?? 0)
        guard id != 0, let info = WindowList.info(id) else { return }
        let agents = AgentDisplay.running.map(\.liveBounds)
        let over = WindowList.above(id).filter { w in
            w.pid == intruder && w.layer == 0 && w.alpha > 0 && w.bounds.intersects(info.bounds)
                && !agents.contains { $0.intersects(w.bounds) }
        }
        guard !over.isEmpty, let ax = AX.window(pid: pid, id: id) else { return }
        AX.perform(ax, "AXRaise")
        let name = NSRunningApplication(processIdentifier: intruder)?.localizedName ?? "pid \(intruder)"
        record("\(name) left a window over yours when it took the front; raised your window back over it")
    }

    // MARK: Tap

    /// Open the gate for an event that can switch apps, before it goes on
    /// (see `FrontGate`): any mouse button, for as long as it's down and a
    /// moment after; cmd+Tab until command is let go; Return, a function
    /// key or a key with a modifier.
    private func openGate(for type: CGEventType, _ event: CGEvent) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            gate.pointer(down: true, ms: Self.clickLiftMs)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            gate.pointer(down: false, ms: Self.clickLiftMs)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let opens = code == 36 || code == 76 || !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            // The switch comes when command is let go, however long that is.
            if event.flags.contains(.maskCommand) && code == 48 {
                gate.switcher(open: true)
            } else if opens || Self.functionKeys.contains(code) {
                gate.liftForKey(ms: Self.keyLiftMs)
            }
        case .flagsChanged:
            if !event.flags.contains(.maskCommand) { gate.switcher(open: false) }
        default:
            break
        }
    }

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
            // Held and going on only now: the gate opened when it was
            // pressed and has shut again since.
            openGate(for: type, event)
            if type == .keyDown || type == .keyUp { noteDelivered(event, type) }
            if Self.isKey(type) {
                lock.lock()
                replaysInFlight = max(0, replaysInFlight - 1)
                let resume = replaysInFlight == 0 && !held.isEmpty && !draining && holdTokens.isEmpty && !holding
                lock.unlock()
                if resume { DispatchQueue.global(qos: .userInteractive).async { self.drain() } }
            }
            return event
        }
        activity.note(type, event)
        if type == .keyDown || Self.isMouseDown(type) { userPressed() }
        userInput(type, event)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .tabletPointer:
            let p = event.location
            lastUserMoveMs.withLock { $0 = nowMs() }
            if let agent = AgentDisplay.fenced(at: p) {
                let q = returnPoint(p, agent: agent, msSinceUserMove: 0)
                if q != p && AgentDisplay.fenced(at: q) == nil {
                    event.location = q
                    CGWarpMouseCursorPosition(q)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
            }
            if type != .mouseMoved {
                lock.lock(); let pressHeld = held.contains { Self.isMouseDown($0.event.type) }; lock.unlock()
                if pressHeld { hold(event); return nil }
            }
            return event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click can bring any app forward (its window, the Dock, a
            // link that opens in the browser): the gate opens before it goes on.
            openGate(for: type, event)
            lock.lock(); lastUserMouseDownMs = nowMs(); let holdAll = !holdTokens.isEmpty || draining; let anySwap = !swapping.isEmpty; lock.unlock()
            noteClick(at: event.location)
            if AgentDisplay.fenced(at: event.location) != nil {
                Log.info("guard: dropped a click on an agent display at \(Int(event.location.x)),\(Int(event.location.y))")
                return nil
            }
            // A click now would make the user's window key mid-swap; hold it.
            if holdAll {
                Log.info("guard: holding a click (\(heldWhy()))")
                hold(event)
                return nil
            }
            // Even in an app they weren't in: a click on its window would
            // activate it and move key under the agent's keystrokes.
            if anySwap, let pid = Self.windowOwner(at: event.location), isSwapping(pid) {
                Log.info("guard: holding a click on pid \(pid), which is mid-swap")
                hold(event)
                return nil
            }
            return event
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            openGate(for: type, event)
            lock.lock(); let holdIt = !holdTokens.isEmpty || draining || held.contains { Self.isMouseDown($0.event.type) }; lock.unlock()
            if holdIt { hold(event); return nil }
            return event
        case .scrollWheel:
            if AgentDisplay.fenced(at: event.location) != nil { return nil }
            return event
        case .keyDown, .keyUp, .flagsChanged:
            let cmdTab = type != .flagsChanged && event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 48
            if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let opens = code == 36 || code == 76 || !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
                openGate(for: type, event)
                lock.lock()
                lastUserKeyMs = nowMs()
                if opens { lastUserOpenKeyMs = nowMs() }
                if cmdTab { lastUserSwitchKeyMs = nowMs() }
                lock.unlock()
            }
            if type == .flagsChanged { openGate(for: type, event) }
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
            let alreadyHolding = holding || !holdTokens.isEmpty || draining || !held.isEmpty || replaysInFlight > 0
            let anySwap = !swapping.isEmpty || !pidHeld.isEmpty || !parked.isEmpty || !arriving.isEmpty || !stranded.isEmpty
            let now = nowMs()
            let anyTaint = taints.values.contains { $0.count > 0 || $0.until >= now }
            lock.unlock()
            if alreadyHolding {
                hold(event)
                return nil
            }
            // Keys for an app whose key window is an agent's right now wait
            // for it to be the user's again. Modifier changes carry no text,
            // and system shortcuts (cmd+Tab) go to macOS, not the app.
            lock.lock(); let enabledShortcuts = enabledSystemShortcuts; lock.unlock()
            if anySwap && type != .flagsChanged && !Self.systemShortcut(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, enabled: enabledShortcuts) {
                let front = BCUFrontProcessPID()
                lock.lock()
                // Or one left on an agent's window: the user just switched
                // to the app, and key moves to their window in a moment.
                let mid = swapping[front] != nil || pidHeld[front] != nil || parked[front] != nil || arriving[front] != nil || stranded.contains(front)
                if mid, let copy = event.copy() {
                    if firstCapture(copy, "held for an app mid-swap") {
                        var p = pidHeld[front] ?? (nowMs(), [])
                        p.events.append(copy)
                        pidHeld[front] = p
                    }
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
                restoreUserFront(from: front, reason: "keystroke")
                return nil
            }
            return passKey(event, type)
        default:
            return event
        }
    }

    /// Why all the user's input is being held right now, for the log.
    private func heldWhy() -> String {
        lock.lock(); defer { lock.unlock() }
        return "hold tokens \(holdTokens.count), draining \(draining), queued \(held.count), replays in flight \(replaysInFlight)"
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

    private static func chars(_ e: CGEvent) -> String {
        var buf = [UniChar](repeating: 0, count: 4)
        var len = 0
        e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        let s = String(utf16CodeUnits: buf, count: len)
        return s == " " ? "␣" : (s.isEmpty ? "#\(e.getIntegerValueField(.keyboardEventKeycode))" : s)
    }

    /// How long the gate stays open after a click (a link clicked in one app
    /// can take a moment to bring the browser forward) and after a key that
    /// can open or switch apps.
    static let clickLiftMs = 1000.0
    static let keyLiftMs = 1500.0
    /// F1–F20, Mission Control and Launchpad: keys that can show another app.
    static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 160, 131]

    /// A key macOS takes for itself rather than the front app's key
    /// window: holding it for that app would only keep the system from it.
    /// The app switcher (cmd+Tab), Spotlight (cmd+Space), input sources
    /// (ctrl+Space), Mission Control and Spaces (ctrl+arrows, the Mission
    /// Control and Launchpad keys) and Force Quit (cmd+opt+Esc).
    /// Only the whole chord: with another modifier it's the app's shortcut
    /// (ctrl+cmd+arrows in Xcode).
    /// `enabled`: the shortcuts in `configurableShortcuts` that are on.
    static func systemShortcut(code: Int64, flags: CGEventFlags, enabled: Set<Chord> = Set(configurableShortcuts.values)) -> Bool {
        let mods = flags.intersection(chordModifiers)
        switch code {
        case 48: return mods == .maskCommand || mods == [.maskCommand, .maskShift]
        case 160, 131: return mods.isEmpty
        case 53: return mods == [.maskCommand, .maskAlternate]
        default: return enabled.contains(Chord(code: code, modifiers: mods.rawValue))
        }
    }

    /// A key with exactly these of cmd, ctrl, opt and shift.
    struct Chord: Hashable {
        let code: Int64
        let modifiers: UInt64
    }

    static let chordModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// The system shortcuts the user can turn off or change in Keyboard
    /// Shortcuts, by their ID in com.apple.symbolichotkeys, with their
    /// default chords: Spotlight, the input source switches, Mission
    /// Control, application windows, and moving a Space left or right.
    static let configurableShortcuts: [String: Chord] = [
        "64": Chord(code: 49, modifiers: CGEventFlags.maskCommand.rawValue),
        "60": Chord(code: 49, modifiers: CGEventFlags.maskControl.rawValue),
        "61": Chord(code: 49, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue),
        "32": Chord(code: 126, modifiers: CGEventFlags.maskControl.rawValue),
        "33": Chord(code: 125, modifiers: CGEventFlags.maskControl.rawValue),
        "79": Chord(code: 123, modifiers: CGEventFlags.maskControl.rawValue),
        "81": Chord(code: 124, modifiers: CGEventFlags.maskControl.rawValue),
    ]

    /// The `configurableShortcuts` that are on, by the user's
    /// `AppleSymbolicHotKeys` (nil: never changed, so all on as default).
    static func enabledShortcuts(_ hotKeys: [String: Any]?) -> Set<Chord> {
        var out = Set<Chord>()
        for (id, chord) in configurableShortcuts {
            guard let entry = hotKeys?[id] as? [String: Any] else { out.insert(chord); continue }
            if let on = entry["enabled"] as? NSNumber, !on.boolValue { continue }
            // parameters: the character (65535 for none), the key code, the modifiers.
            if let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [NSNumber], p.count >= 3 {
                out.insert(Chord(code: p[1].int64Value, modifiers: p[2].uint64Value & chordModifiers.rawValue))
            } else {
                out.insert(chord)
            }
        }
        return out
    }

    /// Read off the tap's thread (`watchUserWindow`): the tap only looks.
    private var enabledSystemShortcuts = Set(FocusGuard.configurableShortcuts.values)
    private var systemShortcutsReadMs = -1.0

    private func refreshSystemShortcuts() {
        guard nowMs() - systemShortcutsReadMs > 5000 else { return }
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        let enabled = Self.enabledShortcuts(hotKeys)
        lock.lock()
        enabledSystemShortcuts = enabled
        systemShortcutsReadMs = nowMs()
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
    /// Note where a click landed and what on, off the event tap: the window
    /// list takes a few milliseconds, accessibility a few more (0.25 s at
    /// most for a busy app), and the windows under the point don't change
    /// that fast. Accessibility only while agents work: it's asked only to
    /// tell whether a click explains an agent's app coming forward.
    /// What the window list says is under a click at `p` (see `ClickTarget.listed`).
    private static func listedTarget(at p: CGPoint) -> ClickTarget {
        let me = getpid()
        let top = Int(CGWindowLevelForKey(.mainMenuWindow))
        let owners = WindowList.all(onScreenOnly: true)
            .filter { $0.pid != me && $0.alpha > 0 && $0.layer < top && $0.bounds.contains(p) }
            .map { (pid: $0.pid, dock: NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == "com.apple.dock") }
        return ClickTarget.listed(owners)
    }

    private func noteClick(at p: CGPoint) {
        let ms = nowMs()
        lock.lock(); let look = screenLook; lastClick = Click(ms: ms, point: p, windows: look); lock.unlock()
        // The window list first, on its own queue, and accessibility for
        // each click on its own (at most 300 ms): a busy app's slow answer
        // for one click mustn't hold up the next click's, say a click on the
        // Dock, which answers in a few ms.
        clickQueue.async {
            let fallback = Self.listedTarget(at: p)
            self.lock.lock()
            if self.lastClick.ms == ms { self.lastClick.fallback = fallback }
            self.lock.unlock()
            let windows = look ?? Self.userScreenWindows()
            self.lock.lock()
            if self.lastClick.ms == ms { self.lastClick.windows = windows }
            self.lock.unlock()
            let busy = !WindowManager.agentPids().isEmpty || !self.activeTaints.isEmpty
            guard busy else {
                self.lock.lock()
                if self.lastClick.ms == ms { self.lastClick.target = fallback }
                self.lock.unlock()
                return
            }
            DispatchQueue.global(qos: .userInteractive).async {
                // A newer click came meanwhile: its answer is the one asked for.
                self.lock.lock(); let current = self.lastClick.ms == ms; self.lock.unlock()
                guard current else { return }
                let (target, element) = Self.whatWasClicked(at: p, listed: fallback)
                self.lock.lock()
                if self.lastClick.ms == ms {
                    // (settleClick may have given up waiting and gone by the
                    // window list; what comes after goes by this.)
                    self.lastClick.target = target
                    self.lastClick.element = element
                }
                self.lock.unlock()
            }
        }
    }

    /// Keeps `screenLook` while agents work (windows, or a step running or
    /// settling); none otherwise.
    private func watchUserScreen() {
        while true {
            let busy = !WindowManager.agentPids().isEmpty || !activeTaints.isEmpty
            let look = busy ? Self.userScreenWindows() : nil
            lock.lock(); screenLook = look; lock.unlock()
            usleep(250_000)
        }
    }

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
        // The user is in an app whose key is parked on an agent's window but
        // its activation went unnoticed: give key to them now.
        let front = BCUFrontProcessPID()
        lock.lock()
        let parkedFront = parked[front] != nil && swapping[front] == nil && arriving[front] == nil
        lock.unlock()
        if parkedFront && !agentCaused(front) {
            DispatchQueue.global(qos: .userInteractive).async { self.unpark(front, reason: "the user is in it") }
        }
        lock.lock()
        var what: [String] = []
        if !holdTokens.isEmpty && now - holdSinceMs > Self.maxHoldMs { holdTokens.removeAll(); what.append("a key swap") }
        if holding && now - holdingSinceMs > Self.maxHoldMs { holding = false; what.append("a focus change") }
        var inFlightLost = 0
        if replaysInFlight > 0 && now - replaysInFlightSinceMs > 500 {
            inFlightLost = replaysInFlight
            replaysInFlight = 0
        }
        let stale = !held.isEmpty && !draining && now - heldSinceMs > Self.maxHoldMs
        // An arrival that never finished (the app isn't answering).
        arriving = arriving.filter { now - $0.value < Self.maxPidHoldMs }
        let stalePids = pidHeld.filter { now - $0.value.sinceMs > Self.maxPidHoldMs }.map(\.key)
        lock.unlock()
        if !what.isEmpty { record("released your input after \(Int(Self.maxHoldMs)) ms held for \(what.joined(separator: " and "))") }
        if inFlightLost > 0 {
            Log.info("guard: \(inFlightLost) replayed key events didn't come back through the tap within 500 ms; going on")
            if !stale && what.isEmpty { drain() }
        }
        if !what.isEmpty || stale { drain(force: true) }
        for pid in stalePids {
            lock.lock()
            let p = pidHeld.removeValue(forKey: pid)
            let drop = Self.dropsExpiredHold(swapping: swapping[pid] != nil, stranded: stranded.contains(pid))
            if let p, !drop {
                if held.isEmpty { heldSinceMs = p.sinceMs }
                held.insert(contentsOf: p.events.map { ($0, pid) }, at: 0)
            }
            lock.unlock()
            if drop, let p {
                // The app has been mid-swap all this time (it isn't answering),
                // or an agent's window still has key there.
                record("COULD NOT give key back in pid \(pid) within \(Int(Self.maxPidHoldMs)) ms: dropped \(p.events.count) of your key events rather than type them into an agent's window")
            } else {
                drain(force: true)
            }
        }
    }

    /// Whether keys held for an app past `maxPidHoldMs` are dropped rather
    /// than replayed.
    /// A stranded app's keys are, like a stuck swap's: the agent's window
    /// still has key there, and replayed they'd go to whatever app the user
    /// has moved to.
    static func dropsExpiredHold(swapping: Bool, stranded: Bool) -> Bool {
        swapping || stranded
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
        var reclaims = ReclaimTries()
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
                    if !keySafe(front) && reclaims.shouldTry(front) {
                        // Reclaim, but without waiting on a swap that may be stuck.
                        let appLock = Engine.inputLock(front)
                        if appLock.lock(before: Date().addingTimeInterval(0.05)) {
                            if !isSwapping(front) { reclaimKey(front) }
                            appLock.unlock()
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
                gate.lift(ms: Self.clickLiftMs)
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
            lock.lock(); removeHeld(e); let first = firstReplay(e, "drain"); lock.unlock()
            guard first else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: FocusGuard.replayMarker)
            if Self.isKey(e.type) {
                lock.lock()
                if replaysInFlight == 0 { replaysInFlightSinceMs = nowMs() }
                replaysInFlight += 1
                lock.unlock()
            }
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

    /// The apps one `drain` has tried to give key back in. A try can take
    /// most of a second (`reclaimKey`, `strand`), and a forced drain drops
    /// the keys it can't send one by one.
    struct ReclaimTries {
        private var tried: Set<pid_t> = []
        /// Whether to try giving key back in `pid` before its next held key.
        mutating func shouldTry(_ pid: pid_t) -> Bool {
            tried.insert(pid).inserted
        }
    }

    /// Lock held. False if this key event was captured already (by `path`).
    private func firstCapture(_ e: CGEvent, _ path: String) -> Bool {
        // Unstamped events (timestamp 0) can't be told apart: never skip them.
        guard Self.isKey(e.type) && e.type != .flagsChanged && e.timestamp != 0 else { return true }
        let id = KeyID(e), now = nowMs()
        if captured.count > 2000 { captured = captured.filter { now - $0.value < 10_000 } }
        if let first = captured[id] {
            Log.info("guard: skipped a second capture of one key event (\(path)): \(e.type == .keyDown ? "down" : "up") \(Self.chars(e)) ts \(e.timestamp), first captured \(Int(now - first)) ms ago")
            return false
        }
        captured[id] = now
        return true
    }

    /// Lock held. False if this key event was replayed already.
    private func firstReplay(_ e: CGEvent, _ path: String) -> Bool {
        // Unstamped events (timestamp 0) can't be told apart: never skip them.
        guard Self.isKey(e.type) && e.type != .flagsChanged && e.timestamp != 0 else { return true }
        let id = KeyID(e), now = nowMs()
        if replayed.count > 2000 { replayed = replayed.filter { now - $0.value < 10_000 } }
        if let first = replayed[id] {
            Log.info("guard: skipped replaying one key event a second time (\(path)): \(e.type == .keyDown ? "down" : "up") \(Self.chars(e)) ts \(e.timestamp), first replayed \(Int(now - first)) ms ago")
            return false
        }
        replayed[id] = now
        return true
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
        guard firstCapture(copy, "held") else { lock.unlock(); return }
        if held.isEmpty { heldSinceMs = nowMs() }
        held.append((copy, front))
        lock.unlock()
    }

    private func nearestUserPoint(_ p: CGPoint, agent: CGRect) -> CGPoint {
        Self.nearestUserPoint(p, agent: agent, users: AgentDisplay.userDisplayIDs().map { CGDisplayBounds($0) }, fenced: AgentDisplay.fencedBounds)
    }

    private func returnPoint(_ p: CGPoint, agent: CGRect, msSinceUserMove: Double) -> CGPoint {
        Self.returnPoint(p, agent: agent, users: AgentDisplay.userDisplayIDs().map { CGDisplayBounds($0) }, fenced: AgentDisplay.fencedBounds, msSinceUserMove: msSinceUserMove)
    }

    /// A cursor found on the agent display this soon after the user moved
    /// the mouse got there by that move (the watch can see it a moment
    /// before the tap takes it back).
    static let userMoveMs = 100.0

    /// Where a cursor found on the agent display `agent` at `p` goes back to,
    /// `msSinceUserMove` after the user last moved the mouse. The user's own
    /// move stops on the edge of their screen, as at any edge, so they can
    /// reach the corner the agent display touches. Anything else put it
    /// there (a warp, a posted event, the tap off): it comes back
    /// `escapeInset` inside, where they can see it.
    static func returnPoint(_ p: CGPoint, agent: CGRect, users: [CGRect], fenced: [CGRect], msSinceUserMove: Double) -> CGPoint {
        nearestUserPoint(p, agent: agent, users: users, fenced: fenced, inset: msSinceUserMove > userMoveMs)
    }

    /// How far inside the screen an escaped cursor goes back: on the edge's
    /// last pixel the arrow is drawn past it (all of it, in the corner the
    /// agent display touches), and the user can't find it.
    static let escapeInset: CGFloat = 32

    /// Where to put a cursor found at `p`, on the agent display `agent` (or
    /// off every display, with `.null`): on the nearest of the user's
    /// displays `users`, `escapeInset` inside each edge it crossed, at a
    /// point no fenced display covers. With `inset` false, on the edge's last
    /// pixel instead.
    static func nearestUserPoint(_ p: CGPoint, agent: CGRect, users: [CGRect], fenced agents: [CGRect], inset useInset: Bool = true) -> CGPoint {
        var best = p
        var bestDistance = CGFloat.infinity
        for r in users {
            // Skip any display that overlaps the agent's (mirroring, mid-rearrangement).
            let overlap = r.intersection(agent)
            if !overlap.isNull && overlap.width > 0 && overlap.height > 0 { continue }
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if agent.contains(q) || agents.contains(where: { $0.contains(q) }) { continue }
            if d < bestDistance {
                bestDistance = d
                let dx = useInset ? min(escapeInset, (r.width - 1) / 2) : 0, dy = useInset ? min(escapeInset, (r.height - 1) / 2) : 0
                var inside = q
                if p.x < r.minX { inside.x += dx } else if p.x > r.maxX - 1 { inside.x -= dx }
                if p.y < r.minY { inside.y += dy } else if p.y > r.maxY - 1 { inside.y -= dy }
                best = agent.contains(inside) || agents.contains(where: { $0.contains(inside) }) ? q : inside
            }
        }
        if bestDistance == .infinity {
            // Not the main display: with the user's asleep, that can be an agent's.
            guard let r = users.first else { return p }
            return CGPoint(x: r.midX, y: r.midY)
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

/// A hold on the user's input (`FocusGuard.beginHold`) that starts only when
/// something first needs it and ends once: after `end`, `start` does nothing.
public final class InputHold {
    private let focusGuard: FocusGuard
    private let lock = NSLock()
    private var token: Int?
    private var sinceMs = 0.0
    private var ended = false

    public init(_ focusGuard: FocusGuard) { self.focusGuard = focusGuard }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !ended, token == nil else { return }
        token = focusGuard.beginHold()
        sinceMs = nowMs()
    }

    /// Ends the hold; returns how long it lasted, or nil if it never started.
    @discardableResult
    public func end() -> Double? {
        lock.lock()
        ended = true
        let t = token
        token = nil
        lock.unlock()
        guard let t else { return nil }
        focusGuard.endHold(t)
        return nowMs() - sinceMs
    }
}

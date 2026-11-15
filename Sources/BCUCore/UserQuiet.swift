import AppKit
import CoreGraphics
import os

/// When to run a step that takes key focus in the app the user is in.
///
/// Such a step freezes the user's window and menu bar under a still copy for
/// 0.2–0.5 s and holds their input. The user doesn't notice that during a
/// pause, when nothing on screen is changing anyway, so the step waits for
/// one: not mid-typing, not right after a click (its result is what they're
/// watching), not mid-drag or mid-scroll, not while a menu is open.
///
/// Typing goes first (`safeTyping`, on unless the user turns it off): a step
/// never starts while the user is typing, however long they type. What
/// they'd get otherwise is their own keys arriving 0.2–0.45 s late each time
/// an agent cuts in, and with several agents in the app that's most of the
/// time. A step still waiting after `typingPatienceMs` fails, so no tool
/// call hangs for as long as someone writes an email, and the agent retries.
///
/// The other waits are kept short so the agent isn't slowed much: after
/// `softCapMs` (not counting time spent on typing) any short gap in the
/// user's input will do, and after `hardCapMs` the step runs anyway (the
/// guard still holds and replays the user's input), except while the user is
/// doing something that breaks when focus moves: a menu open, a mouse button
/// held (a drag, a selection, a slider) or a key held. Then it fails instead
/// and the agent retries. With `safeTyping` off, typing is waited for the
/// same short way: the agent is quicker in the app the user writes in, and
/// their keys can arrive late.
///
/// The rule, for every agent step that can move focus: never while the user
/// is mid such an action. In the app the user is in (a key swap, a new
/// window there, a URL loading there) the full pause rules apply; anywhere
/// else, a step that may bring its app to the front (opening a window:
/// Chromium does) waits only for those focus-sensitive moments, wherever
/// the user is.
public enum QuietRules {
    /// "Safe typing" in Settings: the user's typing has no cap (see above).
    /// Off, a step waits for a pause in typing as it does for a click, up to
    /// the caps, then goes in between two keystrokes; `priority: "now"`
    /// skips that wait too. BCU_SAFE_TYPING=0 at launch starts with it off
    /// (for an engine with no Settings window); it can change at any time,
    /// and a step that's waiting follows it.
    public static var safeTyping: Bool {
        get { safeTypingFlag.withLock { $0 } }
        set { safeTypingFlag.withLock { $0 = newValue } }
    }
    private static let safeTypingFlag = OSAllocatedUnfairLock(
        initialState: ProcessInfo.processInfo.environment["BCU_SAFE_TYPING"] != "0")

    /// Typing: this long since the last key went down, and no key held.
    /// Long enough that the gaps inside typing don't count as its end: at 20
    /// words a minute a key goes down every 600 ms, and anyone writing
    /// stops for a second now and then to find a word. Two seconds is where
    /// studies of writing put the end of a burst of typing. It also decides
    /// how often a step is caught mid-way by the user starting again (their
    /// first keys then wait for it to finish): a step that has been waiting
    /// starts the moment this has passed, so the shorter it is, the more of
    /// the pauses it starts in are the short ones about to end. Measured
    /// with 1 s, on pauses of 1.1–2.9 s: 1 key in 30 late with three
    /// agents in the user's browser.
    ///
    /// With `safeTyping` off it's half a second: enough to start in a
    /// pause rather than mid-word, when the step would go in at the cap anyway.
    public static var typingMs: Double { safeTyping ? 2000 : 500 }
    /// A step waits this long for the user to stop typing, then fails
    /// (the agent retries). Under what MCP clients give a tool call (60 s in
    /// several), since the step itself still has to run after the wait.
    public static let typingPatienceMs = 30_000.0
    /// Clicking: this long since the last mouse button came up, so the
    /// click's result (a page loading, a menu opening) plays out unfrozen.
    /// At least the double-click interval, so a double click isn't split.
    public static var clickMs: Double { max(700, NSEvent.doubleClickInterval * 1000) }
    /// Scrolling: this long after the last scroll event, momentum included.
    public static let scrollMs = 200.0
    /// A trackpad scroll phase that's still "changing" with no events for
    /// this long (fingers resting) counts as ended.
    public static let scrollPhaseStaleMs = 1000.0
    /// After this, run at the first gap of `gapMs` with no input at all.
    public static let softCapMs = 2000.0
    public static let gapMs = 150.0
    /// After this, run whatever the user is doing.
    public static let hardCapMs = 3000.0
    /// A key or mouse button down this long is being held (a drag, a
    /// selection, a key repeating, a modifier kept down), not pressed: while
    /// typing a key is down about 40% of the time, for 40–100 ms at a go.
    public static let heldMs = 350.0
    /// At the cap, how long to wait for the instant between two keystrokes.
    static let betweenKeysMs = 250.0
    /// Shared budget: a session's waits (other than for typing) may add up
    /// to `budgetShare` of the time its agent has been working (the last
    /// `budgetWindowMs` at most, counted as at least `budgetMinSpanMs`, so a
    /// new task has 3 s). A wait gets the hard cap or what's left of the
    /// budget, whichever is less, but at least `budgetFloorMs` to find a
    /// gap; the soft cap is the hard cap less `softCapLeadMs`. So a user who
    /// never stops clicking and scrolling slows a task down by about a fifth.
    public static let budgetShare = 0.2
    public static let budgetWindowMs = 60_000.0
    public static let budgetMinSpanMs = 15_000.0
    public static let budgetFloorMs = 200.0
    static let softCapLeadMs = hardCapMs - softCapMs
    /// How often a wait looks again, and how often it lists windows for menus.
    static let pollMs = 10.0
    static let menuPollMs = 30.0
}

/// What the user's keyboard, mouse and trackpad did last, written by the
/// guard's event tap (its own thread, a few field reads and a lock per
/// event) and read by `QuietWait`. Events the guard replays are skipped, and
/// the agent's own input is posted to its process and never reaches the tap.
public final class UserActivity {
    public struct Snapshot {
        public var lastKeyDownMs = -Double.infinity
        public var lastMouseUpMs = -Double.infinity
        public var lastScrollMs = -Double.infinity
        /// Any key, button, modifier or scroll event, but not a mouse move.
        public var lastInputMs = -Double.infinity
        public var keysDown: Set<Int64> = []
        public var modifiersDown = false
        public var buttonsDown: UInt32 = 0
        /// When each key that's down went down, and when the modifiers and
        /// the mouse buttons that are down first did.
        public var keyDownAtMs: [Int64: Double] = [:]
        public var modifiersDownAtMs = 0.0
        public var buttonsDownAtMs = 0.0
        /// The trackpad says a scroll or its momentum is still going.
        public var scrollOngoing = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    /// Tap thread.
    func note(_ type: CGEventType, _ event: CGEvent) {
        let now = nowMs()
        switch type {
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            state.withLock { s in
                s.lastKeyDownMs = now; s.lastInputMs = now
                // (Autorepeats of a key that's down keep when it went down.)
                if s.keysDown.insert(code).inserted { s.keyDownAtMs[code] = now }
            }
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            state.withLock { s in s.lastInputMs = now; s.keysDown.remove(code); s.keyDownAtMs[code] = nil }
        case .flagsChanged:
            let held = !event.flags.intersection(Self.modifierMask).isEmpty
            state.withLock { s in
                s.lastInputMs = now
                if held && !s.modifiersDown { s.modifiersDownAtMs = now }
                s.modifiersDown = held
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let bit = UInt32(1) << UInt32(min(31, max(0, event.getIntegerValueField(.mouseEventButtonNumber))))
            state.withLock { s in
                s.lastInputMs = now
                if s.buttonsDown == 0 { s.buttonsDownAtMs = now }
                s.buttonsDown |= bit
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let bit = UInt32(1) << UInt32(min(31, max(0, event.getIntegerValueField(.mouseEventButtonNumber))))
            state.withLock { s in s.lastInputMs = now; s.lastMouseUpMs = now; s.buttonsDown &= ~bit }
        case .scrollWheel:
            // Phases: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin.
            // Momentum: 1 begin, 2 continue, 3 end. A mouse wheel sets neither.
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let ongoing = phase == 1 || phase == 2 || phase == 128 || momentum == 1 || momentum == 2
            state.withLock { s in s.lastInputMs = now; s.lastScrollMs = now; s.scrollOngoing = ongoing }
        default:
            break
        }
    }

    public var snapshot: Snapshot {
        var copy = state.withLock { $0 }
        // A key, modifier or button whose release the tap missed (it was off
        // for a moment) would hold up every wait until the cap: after a
        // second with no input, ask the HID system what's really down.
        guard nowMs() - copy.lastInputMs > 1000 else { return copy }
        if !copy.keysDown.isEmpty, !copy.keysDown.contains(where: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }) {
            copy.keysDown = []
            copy.keyDownAtMs = [:]
        }
        if copy.modifiersDown, CGEventSource.flagsState(.hidSystemState).intersection(Self.modifierMask).isEmpty {
            copy.modifiersDown = false
        }
        if copy.buttonsDown != 0, ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.hidSystemState, button: $0) }) {
            copy.buttonsDown = 0
        }
        return copy
    }
}

/// Waits for a moment the user won't notice a key-focus swap in their app.
enum QuietWait {
    /// `menu`: the hard cap came with a menu open in the target app, so the
    /// step mustn't run. `stopped`: the user paused the agent meanwhile.
    /// `held`: the user still held a mouse button (a drag, say) or a key at
    /// the cap; moving focus would interrupt it, so the step doesn't run.
    /// `typing`: the user typed for the whole of `patienceMs`; the step
    /// doesn't run.
    enum Outcome { case quiet, gap, cap, menu, held, typing, stopped }

    struct Result {
        var waitedMs: Double
        /// The part of the wait that wasn't for typing: what the caps and
        /// the session's budget count.
        var countedMs: Double
        /// What the user was doing for most of the wait.
        var reason: String?
        var outcome: Outcome
    }

    static let typingReason = "the user to stop typing"

    /// The user is typing: a key went down within `typingMs`. A key kept
    /// down counts for as long as it repeats.
    static func typing(_ s: UserActivity.Snapshot, now: Double) -> Bool {
        now - s.lastKeyDownMs < QuietRules.typingMs
    }

    /// Why now isn't quiet, or nil if it is.
    static func blocker(_ s: UserActivity.Snapshot, menuOpen: Bool, now: Double) -> String? {
        if !s.keysDown.isEmpty || s.modifiersDown { return "the user to let go of a key" }
        if s.buttonsDown != 0 { return "the user to let go of the mouse button" }
        if menuOpen { return "the user to close a menu" }
        if typing(s, now: now) { return typingReason }
        if (s.scrollOngoing && now - s.lastScrollMs < QuietRules.scrollPhaseStaleMs) || now - s.lastScrollMs < QuietRules.scrollMs {
            return "the user to stop scrolling"
        }
        if now - s.lastMouseUpMs < QuietRules.clickMs { return "the user's click to play out" }
        return nil
    }

    /// The user is mid something that moving focus would break: a key or
    /// modifier held, a mouse button held, a menu open.
    static func focusSensitive(_ s: UserActivity.Snapshot, menuOpen: Bool) -> String? {
        if !s.keysDown.isEmpty || s.modifiersDown { return "the user to let go of a key" }
        if s.buttonsDown != 0 { return "the user to let go of the mouse button" }
        if menuOpen { return "the user to close a menu" }
        return nil
    }

    /// The user is holding something down (see `QuietRules.heldMs`), as
    /// against being between the down and the up of a keystroke or a click:
    /// what they're doing would break if focus moved now, and waiting a
    /// moment won't end it.
    static func holding(_ s: UserActivity.Snapshot, now: Double) -> Bool {
        if s.keyDownAtMs.values.contains(where: { now - $0 > QuietRules.heldMs }) { return true }
        if s.modifiersDown && now - s.modifiersDownAtMs > QuietRules.heldMs { return true }
        if s.buttonsDown != 0 && now - s.buttonsDownAtMs > QuietRules.heldMs { return true }
        return false
    }

    /// At the cap with nothing held but a key or button down all the same
    /// (the user is typing or clicking): the moment it's up, at most
    /// `betweenKeysMs` away. False if it turned into a hold meanwhile.
    static func betweenKeys(_ activity: UserActivity) -> Bool {
        let deadline = nowMs() + QuietRules.betweenKeysMs
        while true {
            let s = activity.snapshot, now = nowMs()
            if s.keysDown.isEmpty && !s.modifiersDown && s.buttonsDown == 0 { return true }
            if holding(s, now: now) { return false }
            if now >= deadline { return true }
            sleepMs(2)
        }
    }

    /// Wait out the user's focus-sensitive moments in any app, for steps that
    /// may bring their app to the front. `menu` or `held` if one outlasts
    /// `hardMs`: the step mustn't run.
    static func waitAnywhere(_ activity: UserActivity, hardMs hard: Double, stop: () -> Bool = { false },
                             willWait: () -> Void = {}) -> Result {
        let start = nowMs()
        var menu = menus().any, menuCheckedMs = start
        var time: [String: Double] = [:]
        var last = start, first = true
        while true {
            let now = nowMs()
            if now - menuCheckedMs >= QuietRules.menuPollMs { menu = menus().any; menuCheckedMs = nowMs() }
            let why = focusSensitive(activity.snapshot, menuOpen: menu)
            if let why { time[why, default: 0] += now - last }
            last = now
            let elapsed = now - start
            func done(_ o: Outcome) -> Result {
                Result(waitedMs: elapsed, countedMs: elapsed, reason: time.max { $0.value < $1.value }?.key, outcome: o)
            }
            if stop() { return done(.stopped) }
            if why == nil { return done(.quiet) }
            if first { first = false; willWait() }
            if elapsed >= hard {
                if menu { return done(.menu) }
                // Down because they're typing, not held: go between two keys.
                return done(betweenKeys(activity) ? .quiet : .held)
            }
            sleepMs(QuietRules.pollMs)
        }
    }

    /// A short gap is enough after the soft cap, but not with a key or
    /// button held or a menu open: those still wait for the hard cap.
    static func gapOK(_ s: UserActivity.Snapshot, menuOpen: Bool, now: Double) -> Bool {
        s.keysDown.isEmpty && !s.modifiersDown && s.buttonsDown == 0 && !menuOpen && now - s.lastInputMs >= QuietRules.gapMs
    }

    /// A menu, context menu, status item menu or pop-up button list is open
    /// on the user's screens (any app's window at the pop-up menu level),
    /// and whether one of them is `pid`'s.
    static func menus(pid: pid_t = 0) -> (any: Bool, app: Bool) {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let me = getpid()
        let open = WindowList.all(onScreenOnly: true).filter { w in
            w.layer == level && w.pid != me && w.alpha > 0 && w.bounds.width > 2 && w.bounds.height > 2
                && !AgentDisplay.running.contains { $0.liveBounds.intersects(w.bounds) }
        }
        return (!open.isEmpty, open.contains { $0.pid == pid })
    }

    static func menuOpen() -> Bool { menus().any }

    /// Block until quiet, or the caps (from the session's `WaitBudget`).
    /// With `QuietRules.safeTyping`, typing has no cap: the wait goes on
    /// until the user stops, or fails with `typing` at `giveUpAtMs`. With
    /// `typingOnly`, nothing else is waited for (a step that passed
    /// `priority: "now"`). `willWait` runs once if it isn't quiet already;
    /// `stop` is checked on every look.
    static func wait(_ activity: UserActivity, pid: pid_t, softMs soft: Double, hardMs hard: Double,
                     typingOnly: Bool = false, giveUpAtMs: Double = .infinity,
                     stop: () -> Bool = { false }, willWait: () -> Void = {}) -> Result {
        let start = nowMs()
        var menu = menus(pid: pid)
        var menuCheckedMs = start
        var time: [String: Double] = [:]
        var last = start
        var first = true
        // Time waited for anything but typing: what the caps run on, so
        // that a click after a long spell of typing still gets its wait.
        var counted = 0.0
        while true {
            let now = nowMs()
            if now - menuCheckedMs >= QuietRules.menuPollMs { menu = menus(pid: pid); menuCheckedMs = nowMs() }
            let s = activity.snapshot
            // Typing that the step may not cut into (looked up on every
            // pass: the user can change the setting during a wait).
            let typing = QuietRules.safeTyping && Self.typing(s, now: now)
            let why = typing ? typingReason : (typingOnly ? nil : blocker(s, menuOpen: menu.any, now: now))
            if let why {
                time[why, default: 0] += now - last
                if !typing { counted += now - last }
            }
            last = now
            let elapsed = now - start
            func done(_ o: Outcome) -> Result {
                Result(waitedMs: elapsed, countedMs: counted, reason: time.max { $0.value < $1.value }?.key, outcome: o)
            }
            if stop() { return done(.stopped) }
            if why == nil { return done(.quiet) }
            if first { first = false; willWait() }
            if typing {
                if now >= giveUpAtMs { return done(.typing) }
            } else {
                if counted >= soft && gapOK(s, menuOpen: menu.any, now: now) { return done(.gap) }
                if counted >= hard {
                    // Taking key focus in an app closes its open menu.
                    if menu.app { menu = menus(pid: pid); menuCheckedMs = nowMs() }
                    if menu.app { return done(.menu) }
                    // A button that's down because they're clicking isn't a
                    // held one: the step goes in once it's up (their input
                    // is held and replayed around it, as at any cap).
                    return done(betweenKeys(activity) ? .cap : .held)
                }
            }
            sleepMs(QuietRules.pollMs)
        }
    }
}

/// How much deferral has cost one session lately, to shrink the caps when a
/// user who never pauses would otherwise slow a long task down a lot.
final class WaitBudget {
    private var waits: [(endMs: Double, ms: Double)] = []
    /// When the agent's current stretch of work began.
    private var since = 0.0
    private var lastStepMs = -Double.infinity

    /// The agent made a call.
    func step() {
        let now = nowMs()
        if now - lastStepMs > QuietRules.budgetWindowMs { since = now }
        lastStepMs = now
    }

    func reset() { waits = []; lastStepMs = -Double.infinity }

    func add(_ ms: Double) {
        guard ms > 0 else { return }
        waits.append((nowMs(), ms))
    }

    /// Waiting time spent recently, and the span it's measured against.
    private func spent() -> (ms: Double, span: Double) {
        let now = nowMs(), from = now - QuietRules.budgetWindowMs
        waits.removeAll { $0.endMs < from }
        // Count only the part of each wait inside the window.
        let total = waits.reduce(0.0) { $0 + min($1.ms, $1.endMs - from) }
        return (total, min(QuietRules.budgetWindowMs, max(QuietRules.budgetMinSpanMs, now - since)))
    }

    var share: Double { let s = spent(); return s.ms / s.span }

    /// The caps for the next wait.
    var caps: (softMs: Double, hardMs: Double) {
        let s = spent()
        let left = QuietRules.budgetShare * s.span - s.ms
        let hard = min(QuietRules.hardCapMs, max(QuietRules.budgetFloorMs, left))
        return (max(0, hard - QuietRules.softCapLeadMs), hard)
    }
}

import AppKit
import CoreGraphics
import os

/// When to run a step that takes key focus in the app the user is in.
///
/// Such a step freezes the user's window and menu bar under a still copy for
/// 0.2–0.5 s and holds their input. The user doesn't notice that during a
/// pause, when nothing on screen is changing anyway, so the step waits for
/// one: not mid-typing, not right after a click (its result is what they're
/// watching), not mid-drag or mid-scroll, not while a menu is open. Waits are
/// kept short so the agent isn't slowed much: after `softCapMs` any short
/// gap in the user's input will do, and after `hardCapMs` the step runs
/// anyway (the guard still holds and replays the user's keys), except while
/// the user is doing something that breaks when focus moves: a menu open, a
/// mouse button held (a drag, a selection, a slider) or a key held. Then it
/// fails instead and the agent retries.
///
/// The rule, for every agent step that can move focus: never while the user
/// is mid such an action. In the app the user is in (a key swap, a new
/// window there) the full pause rules apply; anywhere else, a step that may
/// bring its app to the front (opening a window: Chromium does) waits only
/// for those focus-sensitive moments, wherever the user is.
public enum QuietRules {
    /// Typing: this long since the last key went down, and no key held.
    public static let typingMs = 500.0
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
    /// Shared budget: a session's waits may add up to `budgetShare` of the
    /// time its agent has been working (the last `budgetWindowMs` at most,
    /// counted as at least `budgetMinSpanMs`, so a new task has 3 s). A wait
    /// gets the hard cap or what's left of the budget, whichever is less,
    /// but at least `budgetFloorMs` to find a gap; the soft cap is the hard
    /// cap less `softCapLeadMs`. So a user who never stops slows a task
    /// down by about a fifth.
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
            state.withLock { s in s.lastKeyDownMs = now; s.lastInputMs = now; s.keysDown.insert(code) }
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            state.withLock { s in s.lastInputMs = now; s.keysDown.remove(code) }
        case .flagsChanged:
            let held = !event.flags.intersection(Self.modifierMask).isEmpty
            state.withLock { s in s.lastInputMs = now; s.modifiersDown = held }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let bit = UInt32(1) << UInt32(min(31, max(0, event.getIntegerValueField(.mouseEventButtonNumber))))
            state.withLock { s in s.lastInputMs = now; s.buttonsDown |= bit }
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
    enum Outcome { case quiet, gap, cap, menu, held, stopped }

    struct Result {
        var waitedMs: Double
        /// What the user was doing for most of the wait.
        var reason: String?
        var outcome: Outcome
    }

    /// Why now isn't quiet, or nil if it is.
    static func blocker(_ s: UserActivity.Snapshot, menuOpen: Bool, now: Double) -> String? {
        if !s.keysDown.isEmpty || s.modifiersDown { return "the user to let go of a key" }
        if s.buttonsDown != 0 { return "the user to let go of the mouse button" }
        if menuOpen { return "the user to close a menu" }
        if now - s.lastKeyDownMs < QuietRules.typingMs { return "the user to stop typing" }
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
            func done(_ o: Outcome) -> Result { Result(waitedMs: elapsed, reason: time.max { $0.value < $1.value }?.key, outcome: o) }
            if stop() { return done(.stopped) }
            if why == nil { return done(.quiet) }
            if first { first = false; willWait() }
            if elapsed >= hard { return done(menu ? .menu : .held) }
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
    /// `willWait` runs once if it isn't quiet already; `stop` is checked
    /// on every look.
    static func wait(_ activity: UserActivity, pid: pid_t, softMs soft: Double, hardMs hard: Double,
                     stop: () -> Bool = { false }, willWait: () -> Void = {}) -> Result {
        let start = nowMs()
        var menu = menus(pid: pid)
        var menuCheckedMs = start
        var time: [String: Double] = [:]
        var last = start
        var first = true
        while true {
            let now = nowMs()
            if now - menuCheckedMs >= QuietRules.menuPollMs { menu = menus(pid: pid); menuCheckedMs = nowMs() }
            let s = activity.snapshot
            let why = blocker(s, menuOpen: menu.any, now: now)
            if let why { time[why, default: 0] += now - last }
            last = now
            let elapsed = now - start
            func done(_ o: Outcome) -> Result {
                Result(waitedMs: elapsed, reason: time.max { $0.value < $1.value }?.key, outcome: o)
            }
            if stop() { return done(.stopped) }
            if why == nil { return done(.quiet) }
            if first { first = false; willWait() }
            if elapsed >= soft && gapOK(s, menuOpen: menu.any, now: now) { return done(.gap) }
            if elapsed >= hard {
                // Taking key focus in an app closes its open menu.
                if menu.app { menu = menus(pid: pid); menuCheckedMs = nowMs() }
                if menu.app { return done(.menu) }
                return done(focusSensitive(activity.snapshot, menuOpen: false) != nil ? .held : .cap)
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

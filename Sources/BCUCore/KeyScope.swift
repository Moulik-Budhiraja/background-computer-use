import AppKit
import CPrivate

/// Makes one window the key window *inside its app* without activating the
/// app or raising anything, and gives key back to the previous window on
/// `exit()`. Keyboard events posted to a process always go to that app's key
/// window, so every keystroke step runs inside one of these.
///
/// Ported from cua-driver's `enter_exact_window_key` (MIT): defocus record for
/// the current key window, focus record for the target, then the make-key
/// pair, each confirmed by re-reading AXFocusedWindow; AXFocusedWindow as a
/// fallback; refuse rather than guess.
public final class KeyScope {
    public enum Prime { case alreadyKey, records, axFocus }

    public let pid: pid_t
    public let target: CGWindowID
    public let previous: CGWindowID?
    public let primed: Prime
    /// The app counted itself inactive before (no AppKit key window at all).
    private let wasInactive: Bool
    private var exited = false

    private static let settleMs: Double = 120

    private init(pid: pid_t, target: CGWindowID, previous: CGWindowID?, primed: Prime, wasInactive: Bool) {
        self.pid = pid
        self.target = target
        self.previous = previous
        self.primed = primed
        self.wasInactive = wasInactive
    }

    public static func enter(pid: pid_t, window target: CGWindowID) throws -> KeyScope {
        let previous = AX.focusedWindowID(pid)
        // AXFocusedWindow keeps naming the last key window after the app goes
        // inactive, when AppKit has no key window at all and keys sent to the
        // app land nowhere (and make it beep). AXFrontmost is AppKit's own
        // "active" flag, so trust the shortcut only when it's set.
        let active = AX.bool(AX.app(pid), "AXFrontmost") == true
        if active && previous == target && AX.focusedElementWindowID(pid) != nil {
            return KeyScope(pid: pid, target: target, previous: previous, primed: .alreadyKey, wasInactive: false)
        }
        // First try is quick (5 ms between records): fast enough that the
        // user's window never repaints as inactive. The second uses cua's settle.
        for settle in [5.0, settleMs] {
            if postRecords(pid: pid, from: previous, to: target, settle: settle) {
                awaitKey(pid: pid, target: target, budgetMs: settle < 50 ? 250 : 400)
                if AX.focusedWindowID(pid) == target {
                    return KeyScope(pid: pid, target: target, previous: previous, primed: .records, wasInactive: !active)
                }
            }
        }
        if let window = AX.window(pid: pid, id: target),
           AX.set(AX.app(pid), "AXFocusedWindow", window) == .success {
            awaitKey(pid: pid, target: target, budgetMs: 200)
            if AX.focusedWindowID(pid) == target {
                return KeyScope(pid: pid, target: target, previous: previous, primed: .axFocus, wasInactive: !active)
            }
        }
        throw ToolError("could not make window \(target) the app's key window without activating it (the app's key window is \(previous.map(String.init) ?? "none")), so no keys were sent. Use accessibility actions (set_value, click on an element) instead.")
    }

    /// Give key back to the window that had it.
    public func exit() {
        guard !exited else { return }
        exited = true
        guard primed != .alreadyKey else { return }
        // The app had no key window before: resign key so it goes back to
        // counting itself inactive, instead of handing key to `previous`.
        if wasInactive && primed == .records {
            _ = BCUPostFocusRecord(pid, target, false)
            return
        }
        guard let previous, previous != target else { return }
        // Only restore to a window that still exists.
        guard WindowList.info(previous) != nil else { return }
        switch primed {
        case .records:
            _ = KeyScope.postRecords(pid: pid, from: target, to: previous, settle: 5)
            KeyScope.awaitKey(pid: pid, target: previous, budgetMs: 250)
            if AX.focusedWindowID(pid) != previous {
                _ = KeyScope.postRecords(pid: pid, from: target, to: previous)
            }
        case .axFocus:
            if let w = AX.window(pid: pid, id: previous) {
                AX.set(AX.app(pid), "AXFocusedWindow", w)
            }
        case .alreadyKey:
            break
        }
        KeyScope.awaitKey(pid: pid, target: previous, budgetMs: 300)
    }

    deinit { exit() }

    @discardableResult
    static func postRecords(pid: pid_t, from current: CGWindowID?, to target: CGWindowID, settle: Double = settleMs) -> Bool {
        var ok = true
        if let current, current != target {
            ok = ok && BCUPostFocusRecord(pid, current, false) == 0
            sleepMs(settle)
        }
        ok = ok && BCUPostFocusRecord(pid, target, true) == 0
        sleepMs(settle)
        ok = ok && BCUPostMakeKeyRecords(pid, target) == 0
        return ok
    }

    static func awaitNoKey(pid: pid_t, budgetMs: Double) {
        let deadline = nowMs() + budgetMs
        while AX.focusedElementWindowID(pid) != nil && nowMs() < deadline {
            sleepMs(2)
        }
    }

    static func awaitKey(pid: pid_t, target: CGWindowID, budgetMs: Double) {
        let deadline = nowMs() + budgetMs
        while AX.focusedWindowID(pid) != target && nowMs() < deadline {
            sleepMs(2)
        }
    }
}

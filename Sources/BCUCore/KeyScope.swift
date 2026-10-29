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
    private var exited = false

    private static let settleMs: Double = 120

    private init(pid: pid_t, target: CGWindowID, previous: CGWindowID?, primed: Prime) {
        self.pid = pid
        self.target = target
        self.previous = previous
        self.primed = primed
    }

    public static func enter(pid: pid_t, window target: CGWindowID) throws -> KeyScope {
        let previous = AX.focusedWindowID(pid)
        if previous == target && AX.focusedElementWindowID(pid) != nil {
            return KeyScope(pid: pid, target: target, previous: previous, primed: .alreadyKey)
        }
        for _ in 0..<2 {
            if postRecords(pid: pid, from: previous, to: target) {
                awaitKey(pid: pid, target: target, budgetMs: 400)
                if AX.focusedWindowID(pid) == target {
                    return KeyScope(pid: pid, target: target, previous: previous, primed: .records)
                }
            }
        }
        if let window = AX.window(pid: pid, id: target),
           AX.set(AX.app(pid), "AXFocusedWindow", window) == .success {
            awaitKey(pid: pid, target: target, budgetMs: 200)
            if AX.focusedWindowID(pid) == target {
                return KeyScope(pid: pid, target: target, previous: previous, primed: .axFocus)
            }
        }
        throw ToolError("could not make window \(target) the app's key window without activating it (the app's key window is \(previous.map(String.init) ?? "none")), so no keys were sent. Use accessibility actions (set_value, click on an element) instead.")
    }

    /// Give key back to the window that had it.
    public func exit() {
        guard !exited else { return }
        exited = true
        guard primed != .alreadyKey, let previous, previous != target else { return }
        // Only restore to a window that still exists.
        guard WindowList.info(previous) != nil else { return }
        switch primed {
        case .records:
            _ = KeyScope.postRecords(pid: pid, from: target, to: previous)
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
    static func postRecords(pid: pid_t, from current: CGWindowID?, to target: CGWindowID) -> Bool {
        var ok = true
        if let current, current != target {
            ok = ok && BCUPostFocusRecord(pid, current, false) == 0
            sleepMs(settleMs)
        }
        ok = ok && BCUPostFocusRecord(pid, target, true) == 0
        sleepMs(settleMs)
        ok = ok && BCUPostMakeKeyRecords(pid, target) == 0
        return ok
    }

    static func awaitKey(pid: pid_t, target: CGWindowID, budgetMs: Double) {
        let deadline = nowMs() + budgetMs
        sleepMs(40)
        while AX.focusedWindowID(pid) != target && nowMs() < deadline {
            sleepMs(30)
        }
    }
}

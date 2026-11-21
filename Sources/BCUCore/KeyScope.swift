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
    public enum Prime { case records, axFocus }

    public let pid: pid_t
    public let target: CGWindowID
    /// The window made key: `target`, or the sheet over it (a file picker,
    /// a save panel), which while it's up is the only one that can be key.
    public let keyWindow: CGWindowID
    /// Where key goes back to on `exit()`.
    public let previous: CGWindowID?
    public let primed: Prime
    /// The app counted itself inactive before (no AppKit key window at all).
    private let wasInactive: Bool
    private var exited = false
    private var confirmed = true

    private static let settleMs: Double = 120
    /// The gap between the records of the first try at giving key back.
    static let giveBackSettleMs: Double = 5

    private init(pid: pid_t, target: CGWindowID, keyWindow: CGWindowID, previous: CGWindowID?, primed: Prime, wasInactive: Bool) {
        self.pid = pid
        self.target = target
        self.keyWindow = keyWindow
        self.previous = previous
        self.primed = primed
        self.wasInactive = wasInactive
    }

    /// `giveBackTo`: the user's window, when they're in the app. Key goes
    /// back there whatever accessibility names as the key window now (it can
    /// be stale), and the target is always made key with fresh records:
    /// trusting a stale "already key" would send the keys to the user's window.
    public static func enter(pid: pid_t, window target: CGWindowID, giveBackTo user: CGWindowID? = nil) throws -> KeyScope {
        let current = AX.focusedWindowID(pid)
        let previous = user ?? current
        // AXFocusedWindow keeps naming the last key window after the app goes
        // inactive, when AppKit has no key window at all and keys sent to the
        // app land nowhere (and make it beep). AXFrontmost is AppKit's own
        // "active" flag.
        let active = AX.bool(AX.app(pid), "AXFrontmost") == true
        // A sheet over the target takes its input, and the target can't be
        // made key while it's up: make the sheet key instead.
        let targetAX = AX.window(pid: pid, id: target)
        let sheetAX = targetAX.flatMap(AX.sheet(of:))
        let sheet = sheetAX.flatMap(AX.windowID).flatMap { $0 != target ? $0 : nil }
        let key = sheet ?? target
        // The window to take key from: the one that has it, or the user's if
        // accessibility says ours has it already.
        let from = current == key ? user : current
        // First try is quick (5 ms between records): fast enough that the
        // user's window never repaints as inactive. The second uses cua's settle.
        for settle in [5.0, settleMs] {
            if postRecords(pid: pid, from: from, to: key, settle: settle) {
                awaitKey(pid: pid, target: key, budgetMs: settle < 50 ? 250 : 400)
                if AX.focusedWindowID(pid) == key {
                    return KeyScope(pid: pid, target: target, keyWindow: key, previous: previous, primed: .records, wasInactive: !active)
                }
            }
        }
        if let window = sheet != nil ? sheetAX : targetAX,
           AX.set(AX.app(pid), "AXFocusedWindow", window) == .success {
            awaitKey(pid: pid, target: key, budgetMs: 200)
            if AX.focusedWindowID(pid) == key {
                return KeyScope(pid: pid, target: target, keyWindow: key, previous: previous, primed: .axFocus, wasInactive: !active)
            }
        }
        // Undo what may still land: records the app hasn't handled yet would
        // make the target key after this returns.
        if let previous, previous != target, previous != key, WindowList.info(previous) != nil {
            _ = postRecords(pid: pid, from: key, to: previous, settle: 5)
            if let w = AX.window(pid: pid, id: previous), AX.focusedWindowID(pid) == key {
                AX.set(AX.app(pid), "AXFocusedWindow", w)
            }
        } else if !active {
            _ = BCUPostFocusRecord(pid, key, false)
        }
        Log.info("keyscope: could not make \(key)\(sheet != nil ? " (the sheet over \(target))" : "") key in pid \(pid) (key is \(AX.focusedWindowID(pid).map(String.init) ?? "none")); undid the records")
        throw ToolError(refusal(sheet: sheet != nil))
    }

    /// Why a step that needed key focus did nothing. No window ids: an agent
    /// took "the app's key window is N" to mean the user was in the app, and
    /// waited for them.
    static func refusal(sheet: Bool) -> String {
        if sheet {
            return "a sheet (a file picker, a save panel or an alert) is open over this window and couldn't be given key focus without activating the app, so keys and pixel clicks can't reach it and nothing was sent. Use its elements by number (click, set_value), or choose_file to pick a file by path. Waiting won't change this."
        }
        return "this window couldn't be made its app's key window without activating the app, so nothing was sent. That's not the user typing: waiting won't change it. Use accessibility actions (set_value, click on an element) instead, or list_windows to look for a dialog of yours that has to be answered first."
    }

    /// The window of ours that's key now: the target, or a sheet over it
    /// (one may have opened or closed during the step).
    private func ownKey() -> CGWindowID? {
        guard let key = AX.focusedWindowID(pid) else { return nil }
        if key == target || key == keyWindow { return key }
        return AX.sheetWindowID(pid: pid, window: target) == key ? key : nil
    }

    /// Our window that's key now, else the one the scope made key.
    public var heldBy: CGWindowID { ownKey() ?? (WindowList.info(keyWindow) != nil ? keyWindow : target) }

    /// End the scope leaving key on the target, in an app the user isn't
    /// in (see `FocusGuard.park`). Returns false, doing nothing, if the app
    /// is in front now or the target lost key: then call `exit`.
    public func keepKey() -> Bool {
        guard !exited, BCUFrontProcessPID() != pid, ownKey() != nil else { return false }
        exited = true
        return true
    }

    /// Give key back to the window that had it. Returns whether that was
    /// confirmed (accessibility names it the key window again).
    @discardableResult
    public func exit() -> Bool {
        guard !exited else { return confirmed }
        exited = true
        let t0 = nowMs()
        // The app had no key window before and still isn't in front: resign
        // key so it goes back to counting itself inactive, instead of
        // handing key to `previous`. (If the user switched to it meanwhile,
        // their window gets key below.)
        let held = heldBy
        if wasInactive && primed == .records && BCUFrontProcessPID() != pid {
            _ = BCUPostFocusRecord(pid, held, false)
            return true
        }
        guard let previous, previous != target, previous != keyWindow, WindowList.info(previous) != nil else {
            if BCUFrontProcessPID() != pid { _ = BCUPostFocusRecord(pid, held, false) }
            return true
        }
        for settle in [Self.giveBackSettleMs, Self.settleMs] {
            switch primed {
            case .records:
                _ = KeyScope.postRecords(pid: pid, from: held, to: previous, settle: settle)
            case .axFocus:
                if let w = AX.window(pid: pid, id: previous) { AX.set(AX.app(pid), "AXFocusedWindow", w) }
            }
            KeyScope.awaitKey(pid: pid, target: previous, budgetMs: settle < 50 ? 250 : 400)
            if AX.focusedWindowID(pid) == previous { return true }
        }
        confirmed = false
        Log.info("keyscope: could not confirm key back on window \(previous) in pid \(pid) after \(Int(nowMs() - t0)) ms (key is \(AX.focusedWindowID(pid).map(String.init) ?? "none"))")
        return false
    }

    deinit { exit() }

    /// After an agent's step in an app the user isn't in: what becomes of key.
    public enum AfterStep: Equatable {
        /// The agent's window keeps it until its next step (`FocusGuard.park`).
        case park
        /// Key goes to the user's window in the app.
        case handTo(CGWindowID)
    }

    /// The agent's window keeps key only while it has a menu, dropdown or
    /// suggestion list open: those close when their window loses key, and the
    /// agent's next step would find them gone. `popupOpen` is one in a window
    /// of its own; `listOpen` is one inside the page, an expanded combobox
    /// (a browser blurs the page when its window loses key, and such a field
    /// empties itself and closes the list on blur). Otherwise key goes to the
    /// user's window, because the app treats the window that last had key as
    /// its current one: a browser opens a link from another app there, and
    /// the user's link would land in the agent's hidden window.
    public static func afterStep(popupOpen: Bool, listOpen: Bool = false, userWindow: CGWindowID?) -> AfterStep {
        guard !popupOpen, !listOpen, let userWindow else { return .park }
        return .handTo(userWindow)
    }

    /// Hand key to `user` (another window of the app) instead of back to
    /// where it came from. The app stays inactive. Whether `user` has it now.
    @discardableResult
    public func handOff(to user: CGWindowID) -> Bool {
        guard !exited else { return false }
        exited = true
        Self.postRecords(pid: pid, from: heldBy, to: user, settle: 5)
        Self.awaitKey(pid: pid, target: user, budgetMs: 250)
        return AX.focusedWindowID(pid) == user
    }

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

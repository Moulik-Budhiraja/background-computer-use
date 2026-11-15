import Foundation

/// Who made an app the front app: an agent's step, or the user.
///
/// Nothing tells one process why another came forward, so this goes by
/// what happened just before: whether an agent's step was acting on the
/// app, and what the user did with the mouse and keyboard.
enum Attribution {
    /// An agent's step acting on the app.
    struct Step {
        /// How many are running now.
        var running: Int
        /// With none running: until when the last one's effects can still land.
        var settleUntilMs: Double
        /// The user's own clicks are the step (they're driving the agent's
        /// window from the expanded view), so a click says nothing.
        var strict: Bool
    }

    struct Facts {
        var nowMs: Double
        /// nil: no agent has acted on the app.
        var step: Step?
        /// When the guard last put the user's app back in front of this one.
        var restoredAwayMs: Double?
        var lastMouseDownMs: Double
        /// The user's last cmd+Tab (or a switch they asked BCU for).
        var lastSwitchKeyMs: Double
        /// The user's last key that could open or switch to an app: Return,
        /// or a key with command, control or option held.
        var lastOpenKeyMs: Double
        /// When the user last came to an app other than this one.
        var arrivedElsewhereMs: Double
    }

    /// How long after a click or cmd+Tab an app coming forward is the user's doing.
    static let switchMs = 400.0
    /// How long after the guard put the user's app back the same app coming
    /// forward again is still the app's own doing.
    static let reassertMs = 1000.0
    /// How long after a key that could open an app one coming forward is the user's doing.
    static let openKeyMs = 1500.0

    /// Whether the app coming forward now is the agent's doing.
    static func agentCaused(_ f: Facts) -> Bool {
        let reasserting = f.restoredAwayMs.map { f.nowMs - $0 < reassertMs } ?? false
        let running = f.step?.running ?? 0
        guard reasserting || f.step.map({ $0.running > 0 || $0.settleUntilMs >= f.nowMs }) == true else { return false }
        let strict = f.step?.strict ?? false
        let click = !strict && f.nowMs - f.lastMouseDownMs < switchMs
        let clickOrSwitch = click || f.nowMs - f.lastSwitchKeyMs < switchMs
        if reasserting || running > 0 { return !clickOrSwitch }
        return !clickOrSwitch && (strict || f.nowMs - f.lastOpenKeyMs >= openKeyMs)
    }
}

/// Whose a window is that came up on an agent display without being asked
/// for: apps put a new window next to their last one, so one the user opens
/// in an app an agent used can land there, and so does one the agent's own
/// step opened (a sign-in popup, a dialog).
enum NewWindow {
    enum Cause: Equatable {
        /// The user opened it: it goes to their screen.
        case user
        /// The agent's step opened it: it's the session's.
        case agent
        /// Can't tell: it stays where it is, and nobody's.
        case unclear
    }

    struct Facts {
        /// When the window was first seen on the agent display.
        var firstSeenMs: Double
        /// The app is in front, and the guard counts it as the user's.
        var userInApp: Bool
        /// The user's last click or key that could open a window.
        var userOpenInputMs: Double
        /// When the session's last step on the app began, if the window
        /// wasn't there before it. nil: no such step.
        var agentBeganMs: Double?
        /// A step on the app is running or has just ended, so what it opens
        /// can still be showing up.
        var stepSettling: Bool
    }

    /// How long after an agent's step began a new window is the step's.
    static let agentMs = 10_000.0

    static func cause(_ f: Facts) -> Cause {
        f.userInApp ? .user : .unclear
    }
}

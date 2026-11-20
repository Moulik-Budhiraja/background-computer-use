import Foundation
import CoreGraphics

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
        /// or a key with command, control or option held. Not evidence
        /// (see `agentCaused`).
        var lastOpenKeyMs: Double
        /// When the user last came to an app other than this one.
        var arrivedElsewhereMs: Double
        /// Whether the user's last click landed on this app (see `ClickTarget.explains`).
        var clickOnApp: Bool = true
    }

    /// How long after a click or cmd+Tab an app coming forward is the user's doing.
    static let switchMs = 400.0
    /// How long after the guard put the user's app back the same app coming
    /// forward again is still the app's own doing.
    static let reassertMs = 1000.0

    /// Whether the app coming forward now is the agent's doing.
    ///
    /// It is while a step on it is running or settling, or just after the
    /// guard put the user's app back in front of it, unless the user clicked
    /// the app (one of its windows, its Dock icon) or pressed cmd+Tab in the
    /// last `switchMs`.
    ///
    /// A click anywhere else isn't evidence. People click all the time in
    /// the app they're in while an agent works, and a click there 200 ms
    /// before the browser came forward left the browser in front of them.
    /// A click that opens something in the agent's app (a link in their
    /// chat app) is caught after the fact (`LateLook`): the app is put back
    /// first, and comes forward once what the click opened shows up.
    ///
    /// One click or cmd+Tab explains one front change. Once the user has
    /// come to another app since, it's used up: they switch away from the
    /// browser, arrive, and the page an agent is loading brings the browser
    /// forward 250 ms later. Counting the same cmd+Tab again left them in
    /// the browser.
    ///
    /// A key that could open an app (Return, a shortcut) isn't evidence.
    /// People press those all the time in the app they're in, and an agent's
    /// app comes forward on nearly every step. Counting them left the
    /// agent's app in front whenever the two fell within 1.5 s.
    static func agentCaused(_ f: Facts) -> Bool {
        let reasserting = f.restoredAwayMs.map { f.nowMs - $0 < reassertMs } ?? false
        guard reasserting || f.step.map({ $0.running > 0 || $0.settleUntilMs >= f.nowMs }) == true else { return false }
        func unanswered(_ ms: Double) -> Bool { f.nowMs - ms < switchMs && ms > f.arrivedElsewhereMs }
        let click = f.step?.strict != true && f.clickOnApp && unanswered(f.lastMouseDownMs)
        return !(click || unanswered(f.lastSwitchKeyMs))
    }

    /// Whether an agent is acting on the app: a step on it running or
    /// settling, or the guard just put the user's app back in front of it.
    static func acting(_ f: Facts) -> Bool {
        let reasserting = f.restoredAwayMs.map { f.nowMs - $0 < reassertMs } ?? false
        return reasserting || f.step.map({ $0.running > 0 || $0.settleUntilMs >= f.nowMs }) == true
    }
}

/// Where a click of the user's landed, for whether it explains an app
/// coming forward.
enum ClickTarget: Equatable {
    /// Not worked out yet: that's done off the event tap, just after the click.
    case pending
    /// A window of this app (nil: no window the guard could name).
    case app(pid_t?)
    /// The Dock: the app whose icon it was, 0 for an icon of something
    /// that isn't running (a folder, the Trash), nil if accessibility
    /// couldn't say.
    case dock(pid_t?)

    /// Whether the click explains `pid` coming forward: it landed on one of
    /// its windows or on its Dock icon. A Dock icon nobody could name may
    /// have been the app's. While it's pending, any click counts: what
    /// asks before it's known (the tap, deciding where a key goes) keeps
    /// the old rule.
    func explains(_ pid: pid_t) -> Bool {
        switch self {
        case .pending: return true
        case .app(let owner): return owner == pid
        case .dock(let app): return app == nil || app == pid
        }
    }

    /// The window list's answer, for when accessibility is too slow: the
    /// apps whose windows are under the click, top first, and which of them
    /// is the Dock. On macOS 26 and later the Dock keeps a window over the
    /// whole screen that clicks pass through, so the first window that isn't
    /// the Dock's is where it went; only Dock windows there, the Dock.
    static func listed(_ owners: [(pid: pid_t, dock: Bool)]) -> ClickTarget {
        if let app = owners.first(where: { !$0.dock }) { return .app(app.pid) }
        return owners.isEmpty ? .app(nil) : .dock(nil)
    }
}

/// What the user clicked, as accessibility tells it.
enum ClickElement: Equatable {
    /// A link, or anything with a URL: it can open a page in a browser.
    case link
    /// Something that isn't a link (its role).
    case other(String)
    /// Nothing useful: an Electron app with its accessibility tree off, a
    /// busy app, a plain container.
    case unknown

    /// Roles that say nothing about what a click does.
    static let generic: Set<String> = ["", "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXApplication"]

    /// `roles`: the element's and its parents', innermost first. `url`:
    /// whether any of them has one.
    static func classify(roles: [String], url: Bool) -> ClickElement {
        if url || roles.contains("AXLink") { return .link }
        guard let first = roles.first, !generic.contains(first) else { return .unknown }
        return .other(first)
    }
}

/// An agent's app the guard put back though the user had just clicked
/// somewhere else. The click may still have opened something in it: a link
/// in their chat app opens in the browser an agent is working in. So the
/// guard looks for a while, and if a window of the app on the user's
/// screens is new or shows another page, brings the app forward with it.
enum LateLook {
    /// How long after the click to keep looking.
    static let forMs = 2000.0
    static let everyMs = 150.0

    /// Not for a click on something that isn't a link. Unknown or not yet
    /// known: look.
    static func wanted(_ element: ClickElement?) -> Bool {
        if case .other = element { return false }
        return true
    }

    struct Facts {
        /// The app is in front already.
        var front: Bool
        /// The user clicked or typed since: they've moved on.
        var inputSince: Bool
        /// The window the click opened or changed in the app, if any.
        var opened: CGWindowID?
    }

    /// The window to bring the app forward with, or nil to leave it.
    static func bringForward(_ f: Facts) -> CGWindowID? {
        f.front || f.inputSince ? nil : f.opened
    }

    /// A window in `now` (the app's windows on the user's screens, id to
    /// title) that's new since `before` (every window on their screens at
    /// the click), or shows another title. With no look from before, nil:
    /// nothing is brought forward on a guess.
    static func opened(before: [CGWindowID: String]?, now: [CGWindowID: String]) -> CGWindowID? {
        guard let before else { return nil }
        return now.keys.sorted().first { id in before[id].map { $0 != now[id] } ?? true }
    }
}

/// An app asking for the user's attention bounces its Dock icon, and with
/// the Dock hidden, brings the Dock up over the user's work until they go
/// to the app. Apps do it for what happens in a window that isn't in front:
/// a dialog or file picker opening, a download finishing. In a window an
/// agent is working in that's never for the user.
enum Bounce {
    /// How long after an agent's step in the app an attention request is
    /// still put down to it.
    static let afterStepMs = 20_000.0

    /// Whether to cancel an attention request: an app agents have windows
    /// in, that the user isn't in, and either an agent acted on it lately
    /// or it has no window on the user's screens (nothing there for them to see).
    static func quiet(userInApp: Bool, agentApp: Bool, sinceStepMs: Double?, userWindows: Int) -> Bool {
        guard agentApp, !userInApp else { return false }
        return userWindows == 0 || (sinceStepMs.map { $0 < afterStepMs } ?? false)
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
    }

    /// How long after an agent's step began a new window is the step's.
    static let agentMs = 10_000.0

    /// With no step of the session's to explain it, a new window in the app
    /// the user is in is theirs, as it always was.
    ///
    /// A window that wasn't there when the session's step on the app began,
    /// and came up within `agentMs` of it, is the step's: a sign-in popup
    /// opens beside the window whose button the agent pressed. Unless the
    /// user is in the app and has clicked or pressed an opening key since
    /// the step began: then either could have opened it, and it goes to
    /// the user. A window of theirs left on the agent display can't be
    /// seen, and what they type next goes into it.
    static func cause(_ f: Facts) -> Cause {
        guard let began = f.agentBeganMs, f.firstSeenMs >= began, f.firstSeenMs - began < agentMs else {
            return f.userInApp ? .user : .unclear
        }
        return f.userInApp && f.userOpenInputMs >= began ? .user : .agent
    }

    /// How long after the user's click or opening key the guard knows which
    /// app it took them to.
    static let guardLagMs = 400.0

    /// Whose a window is that came up on the user's screen, in an app the
    /// session acted on: `.agent` moves it to the agent display. nil: too
    /// soon to tell.
    ///
    /// The same rule as on the agent display (`cause`). A step's window can
    /// come up well after the step: a browser shows its Save panel about a
    /// second after the press that asked for it, past the step's grace
    /// period, and it sat over the user's work until the agent got to it.
    /// Nor does the user being in the app make it theirs; only a click or
    /// opening key of theirs since the step began does.
    ///
    /// Right after such a click it waits until the guard knows whether the
    /// click took them to the app (a link clicked in another app).
    static func fromUserScreen(_ f: Facts, nowMs: Double) -> Cause? {
        if let began = f.agentBeganMs, f.userOpenInputMs >= began, nowMs - f.userOpenInputMs < guardLagMs { return nil }
        return cause(f)
    }
}

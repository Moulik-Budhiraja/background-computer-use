import Foundation

/// When a downloaded update may relaunch the app on its own. Relaunching
/// closes the agents' windows, so a session with windows open has to have
/// gone quiet for a while first, and nothing may be waiting on the user.
public enum UpdateGate {
    /// A session with windows open and no call for this long has stopped.
    public static let quietMs: Double = 30 * 60_000

    public struct Session {
        public var msSinceLastCall: Double
        /// Windows open, or an agent display up.
        public var hasWindows: Bool
        public var handedOff: Bool
        public var userInControl: Bool
        /// Since the user last gave the agent its windows back (Done on a
        /// handoff, Resume, or the end of a take-over); `.infinity` if never.
        public var msSinceUserReturned: Double

        public init(msSinceLastCall: Double, hasWindows: Bool, handedOff: Bool, userInControl: Bool, msSinceUserReturned: Double = .infinity) {
            self.msSinceLastCall = msSinceLastCall
            self.hasWindows = hasWindows
            self.handedOff = handedOff
            self.userInControl = userInControl
            self.msSinceUserReturned = msSinceUserReturned
        }
    }

    /// `setupOpen`: the user is in Setup or Settings.
    public static func canInstall(_ sessions: [Session], setupOpen: Bool) -> Bool {
        guard !setupOpen else { return false }
        return sessions.allSatisfy { s in
            if s.handedOff || s.userInControl { return false }
            // A call just ran; give the agent a moment to make its next.
            if s.msSinceLastCall < 3000 { return false }
            // The user handing windows back counts as a call: the agent
            // may be waiting for that to carry on.
            return !s.hasWindows || min(s.msSinceLastCall, s.msSinceUserReturned) >= quietMs
        }
    }
}

extension UpdateGate.Session {
    public init(_ e: Engine) {
        self.init(msSinceLastCall: e.msSinceLastCall,
                  hasWindows: e.display.isRunning || !e.windows.windows.isEmpty,
                  handedOff: e.handoffWindow != nil,
                  userInControl: e.userInControl,
                  msSinceUserReturned: e.msSinceUserReturned)
    }
}

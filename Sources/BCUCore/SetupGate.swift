/// Whether setup shows at launch.
public enum SetupGate {
    /// `done`: setup was finished once. `reopened`: setup quit the app to
    /// pick up Screen Recording and should carry on. `ready` (asked only
    /// when needed): the permissions are on and an agent is connected.
    public static func shouldShow(done: Bool, reopened: Bool, ready: () -> Bool) -> Bool {
        // Before `done`: setup run again from the ⋯ menu can quit and reopen too.
        if reopened { return true }
        if done { return false }
        return !ready()
    }
}

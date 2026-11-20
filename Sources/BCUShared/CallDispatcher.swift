import Foundation

/// Finds which caller each tool call belongs to and hands the call on.
/// Finding the caller can take a while (a Claude Code subagent's call waits
/// for its transcript to land), so that can run off the reading thread.
public final class CallDispatcher {
    private let lookups = DispatchQueue(label: "bcu.mcp.lookup", attributes: .concurrent)

    public init() {}

    /// `resolve` finds the call's caller: on this thread, or on a background
    /// queue when `slow`. `deliver` then gets the caller.
    public func submit<Caller>(slow: Bool, resolve: @escaping () -> Caller, deliver: @escaping (Caller) -> Void) {
        if slow {
            lookups.async { deliver(resolve()) }
        } else {
            deliver(resolve())
        }
    }
}

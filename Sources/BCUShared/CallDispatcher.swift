import Foundation

/// Finds which caller each tool call belongs to and hands the call on, in
/// the order the calls arrived. Finding the caller can take a while (a
/// Claude Code subagent's call waits for its transcript to land), so that
/// can run off the reading thread, and several lookups run at once. A call
/// is handed on only after every call that arrived before it: a lookup
/// can't tell in advance whose call it is, so an agent's click can't be
/// overtaken by its own later keypress.
public final class CallDispatcher {
    private let lookups = DispatchQueue(label: "bcu.mcp.lookup", attributes: .concurrent)
    private let lock = NSLock()
    private var nextSeq = 0
    private var nextToDeliver = 0
    private var ready: [Int: () -> Void] = [:]

    public init() {}

    /// `resolve` finds the call's caller: on this thread, or on a background
    /// queue when `slow`. `deliver` then gets the caller, in arrival order.
    /// `deliver` runs under a lock and must only enqueue work.
    public func submit<Caller>(slow: Bool, resolve: @escaping () -> Caller, deliver: @escaping (Caller) -> Void) {
        lock.lock()
        let seq = nextSeq
        nextSeq += 1
        lock.unlock()
        if slow {
            lookups.async {
                let caller = resolve()
                self.finish(seq) { deliver(caller) }
            }
        } else {
            let caller = resolve()
            finish(seq) { deliver(caller) }
        }
    }

    private func finish(_ seq: Int, _ work: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        ready[seq] = work
        while let next = ready.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            next()
        }
    }
}

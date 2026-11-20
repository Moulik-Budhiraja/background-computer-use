import Foundation

/// Holds only the newest value between a producer and a slower consumer:
/// a value put while one waits replaces it, so the consumer never falls behind.
public final class Mailbox<Value> {
    private let lock = NSLock()
    private var value: Value?

    public init() {}

    /// True when the box was empty, so the caller schedules a `take`.
    @discardableResult
    public func put(_ v: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = value == nil
        value = v
        return wasEmpty
    }

    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        defer { value = nil }
        return value
    }
}

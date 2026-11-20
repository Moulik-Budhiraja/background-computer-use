import XCTest
import BCUShared

/// `bcu mcp` hands each tool call to its caller's lane. Finding the caller
/// can take a while for one call and none for the next.
final class CallDispatcherTests: XCTestCase {
    /// One agent's calls reach its lane in the order they arrived, even when
    /// the first one's lookup is the slowest.
    func testCallsAreDeliveredInArrivalOrder() {
        let dispatcher = CallDispatcher()
        let lock = NSLock()
        var got: [Int] = []
        let done = expectation(description: "all delivered")
        done.expectedFulfillmentCount = 3
        func deliver(_ n: Int) {
            lock.lock(); got.append(n); lock.unlock()
            done.fulfill()
        }
        dispatcher.submit(slow: true, resolve: { usleep(200_000); return 1 }, deliver: deliver)
        dispatcher.submit(slow: true, resolve: { 2 }, deliver: deliver)
        dispatcher.submit(slow: false, resolve: { 3 }, deliver: deliver)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, [1, 2, 3])
    }

    /// A call behind a slow lookup doesn't block the thread reading stdin.
    func testSubmitDoesNotWaitForAnEarlierLookup() {
        let dispatcher = CallDispatcher()
        let done = expectation(description: "delivered")
        done.expectedFulfillmentCount = 2
        dispatcher.submit(slow: true, resolve: { usleep(300_000); return 1 }, deliver: { _ in done.fulfill() })
        let start = Date()
        dispatcher.submit(slow: false, resolve: { 2 }, deliver: { _ in done.fulfill() })
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        wait(for: [done], timeout: 5)
    }
}

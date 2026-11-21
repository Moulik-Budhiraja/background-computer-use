import XCTest
@testable import BCUCore

/// Giving key back after a swap posts a defocus record for the agent's
/// window, a focus record for the user's window and the make-key pair.
/// Measured on macOS 27.0 with Helium (12 hand-backs each): with 5 ms
/// between the records, key never moved in 7 of 12, and the user's keys
/// waited for the second try (about half a second in all); with 40 ms it
/// moved in 12 of 12, 10-55 ms after the records.
final class GiveBackRecordsTests: XCTestCase {
    func testTheFirstTryLeavesTheAppTimeBetweenRecords() {
        XCTAssertGreaterThanOrEqual(KeyScope.giveBackSettleMs, 40)
    }
}

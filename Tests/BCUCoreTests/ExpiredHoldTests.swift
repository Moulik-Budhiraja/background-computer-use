import XCTest
@testable import BCUCore

/// What happens to keys held for an app once `maxPidHoldMs` runs out.
final class ExpiredHoldTests: XCTestCase {
    /// A stranded app's keys were moved to the replay queue, and replayed
    /// into whatever app the user had moved to (cmd+W included).
    func testAStrandedAppsKeysAreDropped() {
        XCTAssertTrue(FocusGuard.dropsExpiredHold(swapping: false, stranded: true))
    }

    func testAStuckSwapsKeysAreDropped() {
        XCTAssertTrue(FocusGuard.dropsExpiredHold(swapping: true, stranded: false))
    }

    func testOtherHeldKeysAreReplayed() {
        XCTAssertFalse(FocusGuard.dropsExpiredHold(swapping: false, stranded: false))
    }
}

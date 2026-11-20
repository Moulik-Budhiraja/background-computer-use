import XCTest
@testable import BCUCore

/// Keys held for an app when it quits.
final class HeldOnQuitTests: XCTestCase {
    /// Kept for a swap that was unwinding, they were replayed into the app
    /// the user was in next once the swap ended (cmd+W included).
    func testAQuitAppsKeysAreDroppedEvenMidSwap() {
        XCTAssertTrue(FocusGuard.dropsHeldOnQuit(swapping: true))
        XCTAssertTrue(FocusGuard.dropsHeldOnQuit(swapping: false))
    }
}

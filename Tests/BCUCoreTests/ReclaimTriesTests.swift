import XCTest
@testable import BCUCore

/// How often one drain of held keys tries to give key back in an app.
final class ReclaimTriesTests: XCTestCase {
    /// A forced drain of a stranded app's keys would otherwise wait on
    /// `strand` once per key: 40 keys took about 10 s, with clicks held.
    func testOneTryPerAppPerDrain() {
        var tries = FocusGuard.ReclaimTries()
        XCTAssertTrue(tries.shouldTry(42))
        XCTAssertFalse(tries.shouldTry(42))
        XCTAssertFalse(tries.shouldTry(42))
    }

    func testAnotherAppGetsItsOwnTry() {
        var tries = FocusGuard.ReclaimTries()
        XCTAssertTrue(tries.shouldTry(42))
        XCTAssertTrue(tries.shouldTry(43))
    }
}

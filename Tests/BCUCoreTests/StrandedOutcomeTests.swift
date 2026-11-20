import XCTest
@testable import BCUCore

/// What happens to the keys held for a stranded app on each check.
final class StrandedOutcomeTests: XCTestCase {
    func testStillStrandedKeepsHolding() {
        XCTAssertEqual(FocusGuard.strandedOutcome(pid: 5, frontBefore: 5, frontAfter: 5, keySafe: false, swapping: false), .wait)
    }

    func testAWindowOfTheUsersWithKeyReleases() {
        XCTAssertEqual(FocusGuard.strandedOutcome(pid: 5, frontBefore: 5, frontAfter: 5, keySafe: true, swapping: false), .release)
    }

    func testLeavingDrops() {
        XCTAssertEqual(FocusGuard.strandedOutcome(pid: 5, frontBefore: 9, frontAfter: 9, keySafe: false, swapping: false), .drop)
    }

    /// Kept for the swap, its end replayed them into the app the user had
    /// moved to (cmd+W included).
    func testLeavingMidSwapDrops() {
        XCTAssertEqual(FocusGuard.strandedOutcome(pid: 5, frontBefore: 9, frontAfter: 9, keySafe: false, swapping: true), .drop)
    }
}

/// The user switched apps while the guard was giving key back.
final class StrandedOutcomeLateSwitchTests: XCTestCase {
    /// Key came back in the app after the user had left it: the keys
    /// would go to the app they're in now.
    func testLeavingDuringTheCallsDrops() {
        XCTAssertEqual(FocusGuard.strandedOutcome(pid: 5, frontBefore: 5, frontAfter: 9, keySafe: true, swapping: false), .drop)
    }
}

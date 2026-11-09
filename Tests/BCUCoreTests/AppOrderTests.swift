import XCTest
@testable import BCUCore

final class AppOrderTests: XCTestCase {
    // pids: 1 the user's app, 2 the app they came from, 3 the agent's browser.
    func testBrowserPushedToSecondIsRepaired() {
        XCTAssertEqual(AppOrder.displaced(before: [1, 2, 3], now: [1, 3, 2], intruders: [3]), 2)
    }

    func testUntouchedOrderIsLeftAlone() {
        XCTAssertNil(AppOrder.displaced(before: [1, 2, 3], now: [1, 2, 3], intruders: [3]))
    }

    func testUserInAnotherAppIsLeftAlone() {
        XCTAssertNil(AppOrder.displaced(before: [1, 2, 3], now: [3, 1, 2], intruders: [3]))
    }

    func testNewSecondTheGuardDidntPushBackIsLeftAlone() {
        // Something the agent never touched came up (the user's own doing).
        XCTAssertNil(AppOrder.displaced(before: [1, 2, 3], now: [1, 4, 2], intruders: [3]))
    }

    func testBrowserAlreadySecondIsLeftAlone() {
        XCTAssertNil(AppOrder.displaced(before: [1, 3, 2], now: [1, 3, 2], intruders: [3]))
    }

    func testPreviousSecondGoneIsLeftAlone() {
        XCTAssertNil(AppOrder.displaced(before: [1, 2, 3], now: [1, 3, 4], intruders: [3]))
    }
}

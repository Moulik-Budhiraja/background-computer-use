import XCTest
@testable import BCUCore

/// Which key windows the guard takes key off when the user has no window
/// of theirs in the app.
final class StrandsKeyTests: XCTestCase {
    let agent = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testAWindowOnTheAgentDisplayIsTakenOff() {
        let user = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(FocusGuard.strandsKey(bounds: CGRect(x: 1600, y: 100, width: 800, height: 600), agents: [agent], users: [user]))
    }

    /// An agent display lying over one of the user's: a window there is on
    /// their screen, and taking key off it would hold their typing.
    func testAWindowWhereAUserDisplayOverlapsIsLeft() {
        let user = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        XCTAssertFalse(FocusGuard.strandsKey(bounds: CGRect(x: 1600, y: 100, width: 800, height: 600), agents: [agent], users: [user]))
    }
}
